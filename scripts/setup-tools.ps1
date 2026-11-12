<#
  setup-tools.ps1 - provision a real bash (PortableGit) and PowerShell 7 (portable) for DSH,
  preferring what the machine already has. No admin required. ASCII only: Windows
  PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

  Two phases:
    Phase A (default)  detect -> use what already exists -> install only what is missing
                       -> make the chosen shell actually win (front of user PATH) -> report.
                       Nothing is upgraded silently.
    Phase B (opt-in)   after the skill is finished, compare against the newest upstream
                       release and offer it. Only -Upgrade (or an accepted offer) downloads
                       and installs it. A machine copy that is already newer is kept as is.

  Params:
    -Root DIR        install root (default %LOCALAPPDATA%\dsh-tools)
    -StateDir DIR    state + offer bookkeeping (default %LOCALAPPDATA%\dsh-windows-shell)
    -GitVersion V    pinned PortableGit release, or 'latest' (default)
    -Ps7Version V    pinned PowerShell release, or 'latest' (default)
    -Mirror LIST     extra download prefixes, ';' separated, tried before the built-in list
    -NoAutoMirror    disable the built-in mirror list and the latency probe
    -ResolveOnly     print detection, plan and upstream versions; download and write nothing
    -DryRun          print every write that would happen; write nothing
    -Upgrade         phase B: download and install the newest release for outdated components
    -AskUpgrade      phase B interactive: ask at the end (skipped when there is no console)
    -Launcher        write <Root>\launch-dsh.cmd so DSH can be started with these dirs first
    -Offline         never use the network; reuse archives already under -Root
    -SkipPath / -SkipGit / -SkipPs7
    -KeepArchives    keep downloaded archives (default: delete them once extracted and on PATH)
    -KeepOldVersions keep retired version directories (default: delete them after an upgrade)
    -PatchProfile    write or refresh the shell-executor block in every profile's
                     cordis.patch.yml (backup first, idempotent, shape-validated);
                     -DryRun previews it without writing
    -Profile NAMES   comma-separated profile names to patch (default: every profile that
                     already has a cordis.patch.yml)
    -Workspace PATH  cwd recorded in the bash-sandbox block (default: current directory)
    -DshHome DIR     DSH home that holds profiles/ (default: DSH_HOME or %USERPROFILE%\.dsh)

  Cleanup runs on every invocation, including the no-op case where the machine is already
  current: leftover archives from an earlier run are removed then. Only direct children of
  -Root are ever touched, and only when they look like something this script installed.
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$StateDir,
  [string]$GitVersion = 'latest',
  [string]$Ps7Version = 'latest',
  [string]$Mirror = '',
  [switch]$NoAutoMirror,
  [switch]$ResolveOnly,
  [switch]$DryRun,
  [switch]$Upgrade,
  [switch]$AskUpgrade,
  [switch]$Launcher,
  [switch]$Offline,
  [switch]$SkipPath,
  [switch]$SkipGit,
  [switch]$SkipPs7,
  [switch]$KeepArchives,
  [switch]$KeepOldVersions,
  [switch]$PatchProfile,
  [string]$Profile = '',
  [string]$Workspace = '',
  [string]$DshHome = '',
  [int]$ProbeTimeoutSec = 25
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# Rule 2 of this skill is "scripts are pure ASCII", and a stray 0x08 byte had already slipped
# into a comment. Check the file itself instead of trusting the rule.
function Test-SelfAscii([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $bad = @()
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    $x = $bytes[$i]
    if ($x -eq 9 -or $x -eq 10 -or $x -eq 13) { continue }
    if ($x -lt 32 -or $x -gt 126) { $bad += $i }
  }
  return $bad
}
$selfBad = @(Test-SelfAscii $PSCommandPath)
if ($selfBad.Count -gt 0) {
  Write-Host ('WARNING: ' + $selfBad.Count + ' non-ASCII/control byte(s) in this script, first at offset ' + $selfBad[0] + ' (see SKILL.md rule 2)')
}

if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh-tools' }
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-shell' }
$Root = $Root.TrimEnd('\')

# PROCESSOR_ARCHITECTURE is this process's bitness, not the machine's: a 32-bit process on a
# 64-bit OS reports x86 and keeps the OS arch in PROCESSOR_ARCHITEW6432. Read the OS arch, so
# a 32-bit host still gets the 32-bit toolchain instead of a 64-bit one it cannot run.
function Get-OsArch {
  $pa = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $pa = $env:PROCESSOR_ARCHITEW6432 }
  if ($pa -eq 'ARM64') { return 'arm64' }
  if ($pa -eq 'x86') { return 'x86' }
  return 'x64'
}

$arch = Get-OsArch

# Built-in mirrors, probed in parallel-ish (HEAD, short timeouts) and used fastest-first.
# Asset mirrors also proxy github.com release downloads; API mirrors must proxy api.github.com,
# which most of them do not - only ones known to answer 200 for the API are listed.
$AssetMirrors = @('https://gh-proxy.com/', 'https://ghfast.top/', 'https://ghproxy.net/')
$ApiMirrors = @('https://gh-proxy.com/')
$Headers = @{ 'User-Agent' = 'dsh-setup-tools' }
$HaveCurl = $null -ne (Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue)
$Wrote = $false

function Write-Log([string]$Text) { Write-Host $Text }
function Write-Plan([string]$Text) { Write-Host ('  ' + $Text) }
function Get-Label([string]$Prefix) { if ($Prefix -eq '') { 'origin' } else { $Prefix } }

function Get-Sha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Split-List([string]$Text) {
  @($Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# Version helpers -----------------------------------------------------------
function ConvertTo-Ver([string]$Text) {
  if (-not $Text) { return $null }
  $t = $Text.Trim()
  $t = $t -replace '^[gG]it version ', ''
  $nums = @($t -split '[^0-9]+' | Where-Object { $_ -ne '' } | Select-Object -First 3)
  if ($nums.Count -eq 0) { return $null }
  while ($nums.Count -lt 3) { $nums += '0' }
  try { return [version]($nums -join '.') } catch { return $null }
}

# A prerelease shares its numeric core with the plain release, so 7.7.0-rc1 must compare
# below 7.7.0: comparing numbers alone reports them as equal and hides a real upgrade.
function Test-PreRelease([string]$Text) {
  return ($Text -match '-[A-Za-z]')
}

# -1 = have is older, 0 = same, 1 = have is newer, -9 = cannot tell
function Compare-Ver([string]$Have, [string]$Want) {
  $h = ConvertTo-Ver $Have
  $w = ConvertTo-Ver $Want
  if ($null -eq $w) { return -9 }
  if ($null -eq $h) { return -1 }
  if ($h -gt $w) { return 1 }
  if ($h -lt $w) { return -1 }
  $hp = Test-PreRelease $Have
  $wp = Test-PreRelease $Want
  if ($wp -and -not $hp) { return 1 }
  if ($hp -and -not $wp) { return -1 }
  if ($hp -and $wp) {
    $hs = ($Have -replace '.*[-]', '')
    $ws = ($Want -replace '.*[-]', '')
    $hn = 0
    $wn = 0
    if ($hs -match '(\d+)$') { $hn = [int]$matches[1] }
    if ($ws -match '(\d+)$') { $wn = [int]$matches[1] }
    if ($hn -gt $wn) { return 1 }
    if ($hn -lt $wn) { return -1 }
  }
  return 0
}

# Detection -----------------------------------------------------------------
function Test-WslPath([string]$Path) {
  if (-not $Path) { return $false }
  $p = $Path.ToLower()
  $sys32 = (Join-Path $env:SystemRoot 'System32').ToLower()
  if ($p.StartsWith($sys32 + '\')) { return $true }
  if ($p.Contains('windowsapps\bash.exe')) { return $true }
  return $false
}

function Get-FirstRealBash {
  foreach ($c in @(Get-Command -Name 'bash' -CommandType Application -All -ErrorAction SilentlyContinue)) {
    if (-not (Test-WslPath $c.Source)) { return $c.Source }
  }
  return $null
}

function Get-FirstPwsh {
  $c = Get-Command -Name 'pwsh' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# The bash that PATH resolves may live in <git>\usr\bin; the directory worth putting on PATH is
# <git>\bin, which holds bash.exe without shadowing every msys tool for the whole session.
function Normalize-ShellDir([string]$Exe) {
  if (-not $Exe) { return $null }
  $dir = Split-Path -Parent $Exe
  if ($dir -match '\\usr\\bin$') {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $dir)
    $cand = Join-Path $gitRoot 'bin'
    if (Test-Path -LiteralPath (Join-Path $cand 'bash.exe')) { return $cand }
  }
  return $dir
}

function Test-WslBashPresent {
  $hits = @()
  foreach ($p in @(
      (Join-Path $env:SystemRoot 'System32\bash.exe'),
      (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\bash.exe'))) {
    if (Test-Path -LiteralPath $p) { $hits += $p }
  }
  $hits
}

# Network -------------------------------------------------------------------
function Test-Head([string]$Url) {
  $bad = [pscustomobject]@{ Ok = $false; Ms = 600000 }
  if (-not $HaveCurl) {
    # Without curl the mirror candidates used to be dropped silently, leaving only the
    # origin - which is the one address that is blocked on the networks this list exists
    # for. Fall back to a .NET HEAD request so mirrors stay usable without curl.
    try {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $req = [Net.WebRequest]::Create($Url)
      $req.Method = 'HEAD'
      $req.Timeout = 8000
      $resp = $req.GetResponse()
      $code = [int]$resp.StatusCode
      $resp.Close()
      $sw.Stop()
      if ($code -ge 200 -and $code -lt 400) { return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds } }
    } catch { }
    return $bad
  }
  $out = & curl.exe -sS -I -L -o NUL --connect-timeout 6 --max-time 12 -w '%{http_code} %{time_total}' $Url 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $bad }
  $parts = @(($out -join ' ').Trim() -split '\s+')
  if ($parts.Count -lt 2) { return $bad }
  $code = $parts[0]
  $secs = 0.0
  [void][double]::TryParse($parts[$parts.Count - 1], [ref]$secs)
  if (@('200', '206', '301', '302', '303', '307', '308') -contains $code) {
    return [pscustomobject]@{ Ok = $true; Ms = [int]($secs * 1000) }
  }
  return $bad
}

# Real throughput on the first 256 KB. A HEAD round-trip only says a source answers: measured
# here, three mirrors differed 5x in throughput and their order changed between runs, so the
# stream itself is timed. A source that ignores Range just streams from byte 0 and is cut at
# --max-time, which still measures throughput. Returns KB/s, or 0 when nothing arrived.
function Test-Throughput([string]$Url) {
  if (-not $HaveCurl) { return 0 }
  # -s (not -sS): with -S curl writes its timeout notice to stderr, and Windows PowerShell 5.1
  # turns native stderr into an error record. No regex escapes here on purpose.
  $out = $null
  try {
    $out = & curl.exe -s -L -o NUL -r 0-262143 --connect-timeout 6 --max-time 10 -w '%{size_download} %{time_total}' $Url 2>$null
  } catch { return 0 }
  if (-not $out) { return 0 }
  $p = @(($out -join ' ').Trim() -split ' +')
  if ($p.Count -lt 2) { return 0 }
  $bytes = 0.0
  $secs = 0.0
  [void][double]::TryParse($p[0], [ref]$bytes)
  [void][double]::TryParse($p[1], [ref]$secs)
  if ($bytes -lt 131072 -or $secs -le 0) { return 0 }
  return [int]($bytes / $secs / 1024)
}

# Prefixes with '' meaning origin. Origin takes part in the race: where GitHub is reachable it
# wins on its own, and where it is blocked it measures 0 and sinks to the back by itself.
function Get-SourceOrder([string]$Url, [string[]]$Extra) {
  $all = @()
  if ($Extra) { $all += $Extra }
  if (-not $NoAutoMirror) {
    foreach ($m in $AssetMirrors) { if ($all -notcontains $m) { $all += $m } }
  }
  $all += ''
  $scored = @()
  foreach ($m in $all) {
    $kb = Test-Throughput ($m + $Url)
    $ms = if ($kb -gt 0) { [int](262144 / ($kb * 1024) * 1000) } else { 600000 }
    $scored += [pscustomobject]@{ Prefix = $m; Kb = $kb; Ms = $ms }
    if ($kb -gt 0) { Write-Plan ('speed ' + (Get-Label $m) + ': ' + $kb + ' KB/s') }
    else { Write-Plan ('speed ' + (Get-Label $m) + ': no data') }
  }
  $fast = @($scored | Where-Object { $_.Kb -gt 0 } | Sort-Object Kb -Descending)
  $slow = @($scored | Where-Object { $_.Kb -le 0 } | Sort-Object Ms)
  $out = @()
  foreach ($s in $fast) { $out += $s.Prefix }
  foreach ($s in $slow) { $out += $s.Prefix }
  return $out
}

function Get-ApiJson([string]$Url) {
  $extra = @()
  if ($Mirror) { $extra += (Split-List $Mirror) }
  $cands = @()
  foreach ($m in $extra) { $cands += $m }
  if (-not $NoAutoMirror) { foreach ($m in $ApiMirrors) { $cands += $m } }
  # only mirrors that answer the API itself; origin is always tried last
  $order = @()
  if ($cands.Count -gt 0) {
    foreach ($m in $cands) { if ((Test-Head ($m + $Url)).Ok) { $order += $m } }
  }
  $order += ''
  foreach ($m in $order) {
    $u = if ($m -eq '') { $Url } else { $m + $Url }
    try {
      return Invoke-RestMethod -Uri $u -UseBasicParsing -Headers $Headers -TimeoutSec $ProbeTimeoutSec
    } catch {
      Write-Plan ('api unreachable via ' + (Get-Label $m) + ': ' + $_.Exception.Message)
    }
  }
  return $null
}

function Resolve-Asset([string]$Repo, [string]$Version, [string]$Pattern) {
  if ($Offline) { return $null }
  if ($Version -ne 'latest') {
    $rel = Get-ApiJson ('https://api.github.com/repos/' + $Repo + '/releases/tags/v' + $Version)
    if (-not $rel) { $rel = Get-ApiJson ('https://api.github.com/repos/' + $Repo + '/releases/tags/' + $Version) }
  } else {
    $rel = Get-ApiJson ('https://api.github.com/repos/' + $Repo + '/releases/latest')
  }
  if (-not $rel) { return $null }
  $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
  if (-not $asset -and $Version -eq 'latest') {
    # Upstream can drop an architecture from the newest release: Git for Windows stopped
    # publishing 32-bit PortableGit after v2.48.1. Walk recent releases and use the newest one
    # that still ships this architecture instead of declaring it unsupported.
    # Newest first, paged: one page of 100 releases does not always reach far enough back
    # (Git for Windows' 32-bit build is several minor versions behind the newest release).
    for ($page = 1; $page -le 3 -and -not $asset; $page++) {
      $list = Get-ApiJson ('https://api.github.com/repos/' + $Repo + '/releases?per_page=100&page=' + $page)
      $items = @($list)
      if ($items.Count -eq 0) { break }
      foreach ($r in $items) {
        if ($r.prerelease -eq $true) { continue }
        $a = $r.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($a) { $asset = $a; $rel = $r; break }
      }
      if ($items.Count -lt 100) { break }
    }
    if ($asset) { Write-Plan ('no ' + $arch + ' asset in the newest release: using ' + $rel.tag_name) }
  }
  if (-not $asset) { throw ('no asset matching ' + $Pattern + ' in release ' + $rel.tag_name) }
  $ver = $asset.name
  $ver = $ver -replace '^[A-Za-z]+-', ''
  # Platform suffix first: the ARM64 asset is PowerShell-<v>-win-arm64.zip, and removing
  # '-arm64.*' first would leave '<v>-win' (a directory named PowerShell-<v>-win).
  $ver = $ver -replace '-win-.*$', ''
  $ver = $ver -replace '-(64-bit|arm64|32-bit).*$', ''
  $digest = $null
  if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
    $digest = ($asset.digest -replace '^sha256:', '').ToLower()
  }
  return @{ Version = $ver; Url = $asset.browser_download_url; Name = $asset.name; Digest = $digest }
}

function Get-Download([string]$Url, [string]$Dest, [string]$Sha256, [string[]]$ExtraMirror) {
  $ok = $Dest + '.ok'
  if ((Test-Path -LiteralPath $Dest) -and (Test-Path -LiteralPath $ok)) {
    $stamp = (Get-Content -LiteralPath $ok -Raw).Trim()
    if (-not $Sha256 -or $stamp -match [regex]::Escape($Sha256)) {
      Write-Plan ('reuse ' + (Split-Path -Leaf $Dest) + ' (archive already verified)')
      return
    }
  }
  if ($Offline) { throw ('offline mode: expected archive ' + $Dest) }
  $part = Join-Path (Split-Path -Parent $Dest) ((Split-Path -Leaf $Dest) + '.part')
  $sources = Get-SourceOrder $Url $ExtraMirror
  foreach ($m in $sources) {
    $u = if ($m -eq '') { $Url } else { $m + $Url }
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    Write-Plan ('downloading ' + (Split-Path -Leaf $Dest) + ' via ' + (Get-Label $m))
    $done = $false
    if ($HaveCurl) {
      # -s keeps this quiet: curl's progress meter goes to stderr, and Windows PowerShell 5.1
      # turns any native stderr into a terminating error that would abort the whole install.
      # --speed-limit/--speed-time abort a mirror that dies mid-file so the loop rotates.
      $doneHere = $false
      try {
        & curl.exe -s -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 --speed-limit 4096 --speed-time 20 -o $part $u 2>$null
        $doneHere = ($LASTEXITCODE -eq 0)
      } catch {
        Write-Plan ('download error from ' + (Get-Label $m) + ', next source')
        $doneHere = $false
      }
      $done = $doneHere
    } else {
      try {
        Invoke-WebRequest -Uri $u -OutFile $part -UseBasicParsing -TimeoutSec 900
        $done = $true
      } catch { $done = $false }
    }
    if (-not $done -or -not (Test-Path -LiteralPath $part)) { continue }
    $len = (Get-Item -LiteralPath $part).Length
    if ($len -lt 1048576) {
      Write-Plan ('source too small (' + $len + ' bytes), next source')
      continue
    }
    if ($Sha256) {
      $got = Get-Sha256 $part
      if ($got -ne $Sha256.ToLower()) {
        Write-Plan ('sha256 mismatch from ' + (Get-Label $m) + ', next source')
        continue
      }
    }
    Move-Item -LiteralPath $part -Destination $Dest -Force
    Set-Content -LiteralPath $ok -Value ([string]$len + ' ' + [string]$Sha256) -Encoding ASCII
    $how = if ($Sha256) { 'sha256 verified' } else { 'size checked only (release publishes no sha256 digest)' }
    Write-Plan ('ok ' + [math]::Round($len / 1MB, 1) + ' MB, ' + $how)
    return
  }
  if ($part -and (Test-Path -LiteralPath $part)) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  throw ('download failed: ' + $Url + ' - try -Mirror <prefix> or -Offline with a pre-placed archive')
}

# User PATH ----------------------------------------------------------------
function Get-UserPathParts {
  @(([Environment]::GetEnvironmentVariable('Path', 'User')) -split ';' | Where-Object { $_ -ne '' })
}

# Front = dirs that must win, in order. Any other entry under -Root is a stale install and is dropped.
function Compose-UserPath([string[]]$Front) {
  $parts = Get-UserPathParts
  $frontLower = @()
  foreach ($f in $Front) { if ($f) { $frontLower += $f.TrimEnd('\').ToLower() } }
  $rootLower = $Root.ToLower() + '\'
  $out = New-Object System.Collections.ArrayList
  foreach ($f in $Front) { if ($f) { [void]$out.Add($f) } }
  foreach ($p in $parts) {
    $pn = $p.TrimEnd('\').ToLower()
    if ($frontLower -contains $pn) { continue }
    if ($pn.StartsWith($rootLower)) { continue }
    [void]$out.Add($p)
  }
  ($out -join ';')
}

function Show-PathDiff([string]$Old, [string]$New) {
  $o = @($Old -split ';' | Where-Object { $_ -ne '' })
  $n = @($New -split ';' | Where-Object { $_ -ne '' })
  Write-Plan ('user PATH before: ' + $o.Count + ' entries')
  if ($n.Count -gt 0) { Write-Plan ('user PATH after : ' + $n.Count + ' entries, first = ' + $n[0]) }
  else { Write-Plan 'user PATH after : empty' }
  foreach ($p in $n) {
    if ($o -notcontains $p) { Write-Plan ('  + ' + $p) }
  }
  foreach ($p in $o) {
    if ($n -notcontains $p) { Write-Plan ('  - ' + $p) }
  }
  if (($o -join ';') -ne ($n -join ';') -and ($o.Count -eq $n.Count)) { Write-Plan '  (same set, order changed: the first entry now wins)' }
}

# State + upgrade offer -----------------------------------------------------
function Read-State {
  $p = Join-Path $StateDir 'state.json'
  if (Test-Path -LiteralPath $p) {
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Save-State($State) {
  if ($DryRun -or $ResolveOnly) { return }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $p = Join-Path $StateDir 'state.json'
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
}

function Invoke-UpgradeOffer([string]$Name, [string]$Have, [string]$Want, $State) {
  $key = $Name
  $declined = $null
  if ($State -and $State.PSObject.Properties.Name -contains 'declined') { $declined = $State.declined.$key }
  if ($declined -eq $Want) {
    Write-Plan ('upgrade available (' + $Name + ' ' + $Have + ' -> ' + $Want + ') but already declined for this version')
    return $false
  }
  $line = 'UPGRADE-OFFER ' + $Name + ' ' + $Have + ' -> ' + $Want
  Write-Log $line
  if ($State) {
    if (-not ($State.PSObject.Properties.Name -contains 'offered')) { $State | Add-Member -NotePropertyName offered -NotePropertyValue ([pscustomobject]@{}) -Force }
    $State.offered | Add-Member -NotePropertyName $key -NotePropertyValue $Want -Force
  }
  if (-not $AskUpgrade) { return $false }
  if ([Console]::IsInputRedirected) {
    Write-Plan 'no console attached: keeping the installed version (re-run with -Upgrade to fetch it)'
    return $false
  }
  $answer = Read-Host ('upgrade ' + $Name + ' ' + $Have + ' -> ' + $Want + ' now? this downloads and needs a DSH restart [y/N]')
  if ($answer -match '^(y|yes)$') { return $true }
  if ($State) {
    if (-not ($State.PSObject.Properties.Name -contains 'declined')) { $State | Add-Member -NotePropertyName declined -NotePropertyValue ([pscustomobject]@{}) -Force }
    $State.declined | Add-Member -NotePropertyName $key -NotePropertyValue $Want -Force
  }
  return $false
}

# Launcher ----------------------------------------------------------------
function Write-Launcher([string[]]$Dirs) {
  $dshExe = $null
  $proc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc) { try { $dshExe = $proc.Path } catch { } }
  if (-not $dshExe) {
    $maybe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
    if (Test-Path -LiteralPath $maybe) { $dshExe = $maybe }
  }
  if (-not $dshExe) { $dshExe = 'DeepSeek Harness.exe' }
  $front = ($Dirs | Where-Object { $_ }) -join ';'
  $lines = @(
    '@echo off',
    'REM Generated by dsh-windows-shell-toolchain.',
    'REM A user-scope PATH entry cannot outrank C:\Windows\System32, so start DSH from here',
    'REM when a WSL bash.exe sits there and breaks the bash tool.',
    ('set "PATH=' + $front + ';%PATH%"'),
    ('start "" "' + $dshExe + '"'),
    ''
  )
  $target = Join-Path $Root 'launch-dsh.cmd'
  if ($DryRun -or $ResolveOnly) {
    Write-Plan ('would write launcher: ' + $target)
    return
  }
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  Set-Content -LiteralPath $target -Value $lines -Encoding ASCII
  Write-Log ('launcher written: ' + $target)
  Write-Log 'Use it to start DSH when a WSL bash.exe sits in System32; a user PATH entry cannot outrank it.'
}

# Profile patch (SKILL.md section 7) ----------------------------------------
# The one step that used to be a hand-written YAML edit. The block is idempotent: it is
# replaced wherever its marker already exists, so re-running never stacks duplicates.
$PatchMarker = '# ===== shell toolchain: bash executor (sandboxing variant) ====='

function New-PatchBlock([string]$WorkspacePath) {
  @(
    $PatchMarker,
    '# Written by setup-tools.ps1 -PatchProfile. Re-running replaces this block;',
    '# everything above the marker is left untouched.',
    '- id: tool-bash',
    "  name: '@deepseek-ai/dsh-tool-bash'",
    '  disabled: false',
    '- id: tool-pwsh',
    "  name: '@deepseek-ai/dsh-tool-pwsh'",
    '  disabled: true',
    '- id: pwsh-sandbox',
    "  name: '@deepseek-ai/dsh-pwsh-sandbox'",
    '  disabled: true',
    '- id: bash-sandbox',
    "  name: '@deepseek-ai/dsh-bash-sandbox'",
    '  disabled: false',
    '  config:',
    ("    cwd: '" + $WorkspacePath + "'"),
    '    timeoutMs: 120000',
    '    maxTimeoutMs: 600000',
    ''
  )
}

# PowerShell 5.1 has no YAML parser, so validate the shape this file must keep: the four ids
# exactly once, no tabs, and every line a comment, a list item or an indented continuation.
function Test-PatchText([string]$Text) {
  $problems = @()
  if ($Text.IndexOf([char]9) -ge 0) { $problems += 'contains a tab character' }
  foreach ($id in @('tool-bash', 'tool-pwsh', 'pwsh-sandbox', 'bash-sandbox')) {
    $c = ([regex]::Matches($Text, ('(?m)^- id: ' + [regex]::Escape($id) + '\s*$'))).Count
    if ($c -ne 1) { $problems += ('entry "' + $id + '" appears ' + $c + ' time(s), expected exactly 1') }
  }
  $n = 0
  foreach ($ln in ($Text -split [string][char]10)) {
    $n++
    if ($ln.Trim() -eq '') { continue }
    if ($ln -match '^#') { continue }
    if ($ln -match '^- ') { continue }
    if ($ln -match '^  ') { continue }
    $problems += ('line ' + $n + ' is not a comment, list item or indented continuation: ' + $ln)
  }
  return $problems
}

function Invoke-ProfilePatch {
  $homeDir = if ($DshHome) { $DshHome } elseif ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $ws = if ($Workspace) { $Workspace } else { (Get-Location).Path }
  if ($ws -match "'") { throw ('workspace path contains a single quote, which this writer cannot quote safely: ' + $ws) }
  $profilesRoot = Join-Path $homeDir 'profiles'
  if (-not (Test-Path -LiteralPath $profilesRoot)) { throw ('no profiles directory at ' + $profilesRoot + ' - pass -DshHome') }
  Write-Log ''
  Write-Log '=== profile patch ==='
  $wanted = @()
  if ($Profile) { $wanted = @($Profile -split ',' | ForEach-Object { $_.Trim() }) }
  $files = @()
  foreach ($d in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($wanted.Count -gt 0 -and ($wanted -notcontains $d.Name)) { continue }
    $p = Join-Path $d.FullName 'cordis.patch.yml'
    if ((Test-Path -LiteralPath $p) -or ($wanted -contains $d.Name)) { $files += $p }
  }
  if ($files.Count -eq 0) { Write-Plan 'no cordis.patch.yml found; nothing patched'; return }
  $block = (New-PatchBlock $ws) -join [string][char]13 + [string][char]10
  foreach ($f in $files) {
    $old = ''
    if (Test-Path -LiteralPath $f) { $old = [System.IO.File]::ReadAllText($f) }
    $idx = $old.IndexOf($PatchMarker)
    $head = if ($idx -ge 0) { $old.Substring(0, $idx) } else { $old }
    $head = $head.TrimEnd() + [string][char]13 + [string][char]10 + [string][char]13 + [string][char]10
    $new = $head + $block
    $problems = @(Test-PatchText $new)
    if ($problems.Count -gt 0) {
      Write-Plan ('rejected, current file left alone: ' + $f)
      foreach ($x in $problems) { Write-Plan ('  - ' + $x) }
      continue
    }
    if ($old -eq $new) { Write-Plan ('already patched, unchanged: ' + $f); continue }
    if ($DryRun -or $ResolveOnly) { Write-Plan ('would patch: ' + $f + ' (cwd ' + $ws + ')'); continue }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination ($f + '.bak-' + $stamp) -Force }
    [System.IO.File]::WriteAllText($f, $new, (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::ReadAllText($f) -ne $new) { throw ('patch write did not take effect: ' + $f) }
    Write-Log ('  patched: ' + $f)
  }
}

# Cleanup -------------------------------------------------------------------
# Deletes only what this script installed: direct children of -Root that carry the shapes it
# creates. Anything the user already had on the machine lives outside -Root and is never in scope.
function Get-DirectChildOfRoot([string]$Path) {
  $res = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  $rootRes = Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue
  if (-not $res -or -not $rootRes) { return $null }
  $full = $res.Path.TrimEnd('\')
  $rootFull = $rootRes.Path.TrimEnd('\')
  if (-not $full.StartsWith($rootFull + '\')) { return $null }
  $rel = $full.Substring($rootFull.Length + 1)
  if ($rel.Contains('\')) { return $null }
  return $full
}

function Get-ManagedKind([string]$Name) {
  if ($Name.StartsWith('git-')) { return 'git' }
  if ($Name.StartsWith('PowerShell-')) { return 'pwsh' }
  return ''
}

function Test-ManagedDirExe([string]$Kind, [string]$DirPath) {
  if ($Kind -eq 'git') { return (Test-Path -LiteralPath (Join-Path $DirPath 'bin\bash.exe')) }
  if ($Kind -eq 'pwsh') { return (Test-Path -LiteralPath (Join-Path $DirPath 'pwsh.exe')) }
  return $false
}

# PortableGit-2.56.1-64-bit.7z.exe -> git-2.56.1 ; PowerShell-7.7.0-win-x64.zip -> PowerShell-7.7.0
function Get-ArchiveTargetDir([string]$Name) {
  if ($Name.StartsWith('PortableGit-')) {
    $rest = $Name.Substring(12)
    $i = $rest.IndexOf('-64-bit')
    if ($i -lt 0) { $i = $rest.IndexOf('-arm64') }
    if ($i -lt 0) { $i = $rest.IndexOf('-32-bit') }
    if ($i -gt 0) { return 'git-' + $rest.Substring(0, $i) }
    return ''
  }
  if ($Name.StartsWith('PowerShell-')) {
    $rest = $Name.Substring(11)
    $i = $rest.IndexOf('-win-')
    if ($i -gt 0) { return 'PowerShell-' + $rest.Substring(0, $i) }
    return ''
  }
  return ''
}

function Remove-OnePath([string]$Path, [switch]$AsDir) {
  try {
    Remove-Item -LiteralPath $Path -Recurse:$AsDir -Force -ErrorAction Stop
    return $true
  } catch {
    $msg = $_.Exception.Message
    $nl = [char]10
    if ($msg.Contains($nl)) { $msg = $msg.Split($nl)[0] }
    Write-Plan ('cleanup: cannot delete ' + $Path + ' (' + $msg + ') - will retry next run')
    return $false
  }
}

# Runs on every invocation, including the no-op case where the machine is already current.
function Invoke-Cleanup([string[]]$ActiveDirs) {
  Write-Log ''
  Write-Log '=== cleanup ==='
  if (-not (Test-Path -LiteralPath $Root)) { Write-Plan 'nothing to clean (no install root)'; return }
  $active = @()
  foreach ($a in $ActiveDirs) { if ($a) { $active += $a.TrimEnd('\').ToLower() } }
  $hasActiveGit = $false
  $hasActivePwsh = $false
  foreach ($a in $ActiveDirs) {
    if (-not $a) { continue }
    $k = Get-ManagedKind (Split-Path -Leaf $a)
    if ($k -eq 'git') { $hasActiveGit = $true }
    if ($k -eq 'pwsh') { $hasActivePwsh = $true }
  }
  $freed = 0
  $dirsGone = 0
  $filesGone = 0
  $children = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)

  foreach ($d in $children) {
    if (-not $d.PSIsContainer) { continue }
    $kind = Get-ManagedKind $d.Name
    if (-not $kind) { continue }
    $full = Get-DirectChildOfRoot $d.FullName
    if (-not $full) { continue }
    if (-not (Test-ManagedDirExe $kind $full)) { continue }
    if ($active -contains $full.ToLower()) { Write-Plan ('keep (in use): ' + $full); continue }
    if ($KeepOldVersions) { Write-Plan ('keep (-KeepOldVersions): ' + $full); continue }
    $size = 0
    $sum = Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if ($sum -and $sum.Sum) { $size = $sum.Sum }
    $mb = [math]::Round($size / 1MB, 1)
    if ($DryRun -or $ResolveOnly) { Write-Plan ('would delete old version: ' + $full + ' (' + $mb + ' MB)'); continue }
    if (Remove-OnePath $full -AsDir) {
      Write-Plan ('deleted old version: ' + $full + ' (' + $mb + ' MB)')
      $freed = $freed + $size
      $dirsGone++
    }
  }

  foreach ($item in $children) {
    if ($item.PSIsContainer) { continue }
    $n = $item.Name
    $isArchive = ($n.StartsWith('PortableGit-') -and $n.EndsWith('.7z.exe')) -or ($n.StartsWith('PowerShell-') -and $n.EndsWith('.zip'))
    $isPart = $n.EndsWith('.part')
    if (-not $isArchive -and -not $isPart) { continue }
    $full = Get-DirectChildOfRoot $item.FullName
    if (-not $full) { continue }
    if ($isArchive) {
      $dirName = Get-ArchiveTargetDir $n
      if (-not $dirName) { continue }
      $kind = Get-ManagedKind $dirName
      $dirPath = Join-Path $Root $dirName
      $redundant = (Test-Path -LiteralPath $dirPath) -and (Test-ManagedDirExe $kind $dirPath)
      if (-not $redundant -and $kind -eq 'git') { $redundant = $hasActiveGit }
      if (-not $redundant -and $kind -eq 'pwsh') { $redundant = $hasActivePwsh }
      if (-not $redundant) { Write-Plan ('keep (no extracted copy yet): ' + $full); continue }
      if ($KeepArchives) { Write-Plan ('keep (-KeepArchives): ' + $full); continue }
    }
    $mb = [math]::Round($item.Length / 1MB, 1)
    if ($DryRun -or $ResolveOnly) { Write-Plan ('would delete: ' + $full + ' (' + $mb + ' MB)'); continue }
    if (Remove-OnePath $full) {
      Write-Plan ('deleted: ' + $full + ' (' + $mb + ' MB)')
      $freed = $freed + $item.Length
      $filesGone++
      $okPath = $full + '.ok'
      if (Test-Path -LiteralPath $okPath) {
        if (Remove-OnePath $okPath) { $filesGone++ }
      }
    }
  }

  if ($DryRun -or $ResolveOnly) { Write-Plan 'plan only: nothing deleted' }
  else { Write-Plan ('cleanup: ' + $dirsGone + ' old dir(s), ' + $filesGone + ' file(s), ' + [math]::Round($freed / 1MB, 1) + ' MB freed') }
}

# ---------------------------------------------------------------------------
if (-not $ResolveOnly -and -not $DryRun -and -not (Test-Path -LiteralPath $Root)) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

Write-Log '=== phase A: detect ==='
$bashExe = $null
$bashVer = $null
$gitVer = $null
$pwshExe = $null
$pwshVer = $null

if (-not $SkipGit) {
  $bashExe = Get-FirstRealBash
  if ($bashExe) {
    try {
      $bv = (& $bashExe -c 'echo $BASH_VERSION' 2>$null | Select-Object -First 1)
      if ($bv) { $bashVer = $bv.Trim() }
      $gv = (& $bashExe -c 'git --version 2>/dev/null' 2>$null | Select-Object -First 1)
      if ($gv -and $gv -match '(\d+(?:\.\d+)+)') { $gitVer = $matches[1] }
    } catch { }
    Write-Log ('  bash: ' + $bashExe)
    Write-Log ('        ' + $(if ($bashVer) { 'bash ' + $bashVer } else { 'version unknown' }) + $(if ($gitVer) { ', git ' + $gitVer } else { '' }))
  } else {
    Write-Log '  bash: none usable on PATH'
  }
}

if (-not $SkipPs7) {
  $pwshExe = Get-FirstPwsh
  if ($pwshExe) {
    try {
      $pv = (& $pwshExe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1)
      if ($pv) { $pwshVer = $pv.Trim() }
    } catch { }
    Write-Log ('  pwsh: ' + $pwshExe + ' (' + $(if ($pwshVer) { $pwshVer } else { 'version unknown' }) + ')')
  } else {
    Write-Log '  pwsh: none on PATH'
  }
}

$wslHits = @(Test-WslBashPresent)
if ($wslHits.Count -gt 0) {
  Write-Log '  warning: WSL bash entry present:'
  foreach ($w in $wslHits) { Write-Log ('    ' + $w) }
  Write-Log '    A user-scope PATH entry cannot outrank it; use -Launcher (see docs) if bash breaks.'
}

Write-Log ''
Write-Log '=== upstream ==='
$gitAsset = $null
$psAsset = $null
if (-not $Offline) {
  if (-not $SkipGit) {
    $gitTag = if ($arch -eq 'arm64') { 'arm64' } elseif ($arch -eq 'x86') { '32-bit' } else { '64-bit' }
    $gitPat = 'PortableGit-[\d.]+-' + $gitTag + '\.7z\.exe$'
    $gitAsset = Resolve-Asset 'git-for-windows/git' $GitVersion $gitPat
    if ($gitAsset) { Write-Log ('  git latest: ' + $gitAsset.Version) } else { Write-Log '  git latest: unknown (network unavailable)' }
  }
  if (-not $SkipPs7) {
    $psTag = if ($arch -eq 'x86') { 'x86' } else { $arch }
    $psPat = 'PowerShell-[\d.]+-win-' + $psTag + '\.zip$'
    $psAsset = Resolve-Asset 'PowerShell/PowerShell' $Ps7Version $psPat
    if ($psAsset) { Write-Log ('  pwsh latest: ' + $psAsset.Version) } else { Write-Log '  pwsh latest: unknown (network unavailable)' }
  }
} else {
  Write-Log '  skipped (offline)'
}

# Decide -------------------------------------------------------------------
$needGit = $false
$needPs7 = $false

if (-not $SkipGit) {
  if (-not $bashExe) { $needGit = $true }
  elseif ($Upgrade -and $gitAsset) {
    $cmp = Compare-Ver $gitVer $gitAsset.Version
    if ($cmp -lt 0) { $needGit = $true }
  }
}

if (-not $SkipPs7) {
  if (-not $pwshExe) { $needPs7 = $true }
  elseif ($Upgrade -and $psAsset) {
    $cmp = Compare-Ver $pwshVer $psAsset.Version
    if ($cmp -lt 0) { $needPs7 = $true }
  }
}

if ($needGit -and -not $gitAsset) { throw ('bash is missing and no release could be resolved; use -Offline with an archive under ' + $Root + ' or fix the network / pass -Mirror') }
if ($needPs7 -and -not $psAsset) { throw ('pwsh is missing and no release could be resolved; use -Offline with an archive under ' + $Root + ' or fix the network / pass -Mirror') }

$gitDir = if ($needGit) { Join-Path $Root ('git-' + $gitAsset.Version) } else { $null }
$psDir = if ($needPs7) { Join-Path $Root ('PowerShell-' + $psAsset.Version) } else { $null }
$bashFinal = if ($needGit) { Join-Path $gitDir 'bin\bash.exe' } else { $bashExe }
$pwshFinal = if ($needPs7) { Join-Path $psDir 'pwsh.exe' } else { $pwshExe }

Write-Log ''
Write-Log '=== plan ==='
if ($needGit) { Write-Plan ('install PortableGit ' + $gitAsset.Version + ' -> ' + $gitDir) }
else { Write-Plan ('use existing bash: ' + $bashExe) }
if ($needPs7) { Write-Plan ('install PowerShell ' + $psAsset.Version + ' -> ' + $psDir) }
else { Write-Plan ('use existing pwsh: ' + $pwshExe) }
if (-not $SkipPath) {
  $front = @()
  if ($bashFinal) { $front += (Normalize-ShellDir $bashFinal) }
  if ($pwshFinal) { $front += (Split-Path -Parent $pwshFinal) }
  $newPath = Compose-UserPath $front
  Show-PathDiff ([Environment]::GetEnvironmentVariable('Path', 'User')) $newPath
}
if ($Launcher) { Write-Plan ('write launcher: ' + (Join-Path $Root 'launch-dsh.cmd')) }

# Upgrade availability (phase B) -------------------------------------------
$state = Read-State
if (-not $state) { $state = [pscustomobject]@{} }
$offers = @()
if ($gitAsset -and $bashExe) {
  $cmp = Compare-Ver $gitVer $gitAsset.Version
  if ($cmp -lt 0) { $offers += @{ Name = 'bash'; Have = $(if ($gitVer) { $gitVer } else { $bashVer }); Want = $gitAsset.Version } }
  elseif ($cmp -gt 0) { Write-Plan ('existing git ' + $gitVer + ' is newer than upstream ' + $gitAsset.Version + ': keeping it') }
}
if ($psAsset -and $pwshExe) {
  $cmp = Compare-Ver $pwshVer $psAsset.Version
  if ($cmp -lt 0) { $offers += @{ Name = 'pwsh'; Have = $pwshVer; Want = $psAsset.Version } }
  elseif ($cmp -gt 0) { Write-Plan ('existing pwsh ' + $pwshVer + ' is newer than upstream ' + $psAsset.Version + ': keeping it') }
}

# Version roots, not PATH entries: cleanup compares directories like git-2.56.1, while the PATH
# front holds git-2.56.1\bin. Comparing the wrong level once marked the live install as retired.
$activeDirs = @()
if ($bashFinal) { $activeDirs += (Split-Path -Parent (Normalize-ShellDir $bashFinal)) }
if ($pwshFinal) { $activeDirs += (Split-Path -Parent $pwshFinal) }

if ($PatchProfile) { Invoke-ProfilePatch }

if ($ResolveOnly -or $DryRun) {
  Invoke-Cleanup $activeDirs
  foreach ($o in $offers) { Write-Log ('UPGRADE-OFFER ' + $o.Name + ' ' + $o.Have + ' -> ' + $o.Want) }
  Write-Log ''
  Write-Log ($(if ($ResolveOnly) { 'resolve-only' } else { 'dry-run' }) + ': nothing downloaded, nothing written')
  exit 0
}

# Execute ------------------------------------------------------------------
if ($needGit) {
  Write-Log ''
  Write-Log '=== installing bash (PortableGit) ==='
  $gitExe = Join-Path $Root $gitAsset.Name
  Get-Download $gitAsset.Url $gitExe $gitAsset.Digest (Split-List $Mirror)
  if (Test-Path -LiteralPath $gitDir) { Remove-Item -LiteralPath $gitDir -Recurse -Force }
  & $gitExe ('-o' + $gitDir) '-y' | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $gitDir 'bin\bash.exe'))) { throw 'extraction produced no bin\bash.exe' }
  Write-Log ('  bash: ' + (Join-Path $gitDir 'bin\bash.exe'))
  & (Join-Path $gitDir 'bin\bash.exe') -c 'echo BASH_VERSION=$BASH_VERSION; uname -s'
  if ($LASTEXITCODE -ne 0) { throw 'bash smoke test failed' }
  $Wrote = $true
}

if ($needPs7) {
  Write-Log ''
  Write-Log '=== installing pwsh (PowerShell 7) ==='
  $zip = Join-Path $Root $psAsset.Name
  Get-Download $psAsset.Url $zip $psAsset.Digest (Split-List $Mirror)
  if (Test-Path -LiteralPath $psDir) { Remove-Item -LiteralPath $psDir -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $psDir -Force
  $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $psDir 'pwsh.exe')
  $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { 'no certificate' }
  Write-Log ('  signature: ' + $sig.Status + ' / ' + $signer)
  if ($sig.Status -ne 'Valid') { throw 'pwsh.exe signature is not valid - refusing to trust this download' }
  & (Join-Path $psDir 'pwsh.exe') -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  $Wrote = $true
}

if (-not $SkipPath) {
  Write-Log ''
  Write-Log '=== user PATH ==='
  $front = @()
  if ($bashFinal) { $front += (Normalize-ShellDir $bashFinal) }
  if ($pwshFinal) { $front += (Split-Path -Parent $pwshFinal) }
  $old = [Environment]::GetEnvironmentVariable('Path', 'User')
  $new = Compose-UserPath $front
  if ($old -eq $new) {
    Write-Log '  already correct, nothing to write'
  } else {
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    $readBack = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($readBack -ne $new) { throw 'user PATH write did not take effect' }
    Write-Log '  written and read back OK'
    Show-PathDiff $old $readBack
    $Wrote = $true
  }
  Write-Log '  NOTE: already-running processes keep their old PATH. Restart DSH.'
}

if ($Launcher) {
  $front = @()
  if ($bashFinal) { $front += (Normalize-ShellDir $bashFinal) }
  if ($pwshFinal) { $front += (Split-Path -Parent $pwshFinal) }
  Write-Launcher $front
}

# Runs after extraction and after the PATH write, so a failed install never costs the old copy.
Invoke-Cleanup $activeDirs

Write-Log ''
Write-Log '=== phase B: upgrade offer ==='
if ($needGit) { $offers = @($offers | Where-Object { $_.Name -ne 'bash' }) }
if ($needPs7) { $offers = @($offers | Where-Object { $_.Name -ne 'pwsh' }) }
$accepted = $false
foreach ($o in $offers) {
  if (Invoke-UpgradeOffer $o.Name $o.Have $o.Want $state) { $accepted = $true }
}
if ($offers.Count -eq 0) { Write-Log '  component(s) are current or upstream is unknown; nothing to offer' }
if ($accepted) { Write-Log '  re-run with -Upgrade to download the accepted version' }

if ($state) {
  if (-not ($state.PSObject.Properties.Name -contains 'checkedAt')) { $state | Add-Member -NotePropertyName checkedAt -NotePropertyValue '' -Force }
  $state.checkedAt = (Get-Date).ToString('o')
  Save-State $state
}

Write-Log ''
if ($PatchProfile) { Write-Log ('DONE. wrote=' + $Wrote + '. Profile patch handled; restart DSH to apply it.') }
else { Write-Log ('DONE. wrote=' + $Wrote + '. Next: apply the DSH profile patch (SKILL.md section 7), then restart DSH.') }
if (-not $Wrote -and $offers.Count -eq 0) { Write-Log 'Nothing needed changing on this machine.' }
