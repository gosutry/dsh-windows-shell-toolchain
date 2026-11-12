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
  [int]$ProbeTimeoutSec = 25
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh-tools' }
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-shell' }
$Root = $Root.TrimEnd('\')

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

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

# -1 = have is older, 0 = same, 1 = have is newer, -9 = cannot tell
function Compare-Ver([string]$Have, [string]$Want) {
  $h = ConvertTo-Ver $Have
  $w = ConvertTo-Ver $Want
  if ($null -eq $w) { return -9 }
  if ($null -eq $h) { return -1 }
  if ($h -gt $w) { return 1 }
  if ($h -lt $w) { return -1 }
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
  if (-not $HaveCurl) { return $bad }
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
  if (-not $asset) { throw ('no asset matching ' + $Pattern + ' in release ' + $rel.tag_name) }
  $ver = $asset.name
  $ver = $ver -replace '^[A-Za-z]+-', ''
  $ver = $ver -replace '-(64-bit|arm64).*$', ''
  $ver = $ver -replace '-win-.*$', ''
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
    $gitPat = 'PortableGit-[\d.]+-' + $(if ($arch -eq 'arm64') { 'arm64' } else { '64-bit' }) + '\.7z\.exe$'
    $gitAsset = Resolve-Asset 'git-for-windows/git' $GitVersion $gitPat
    if ($gitAsset) { Write-Log ('  git latest: ' + $gitAsset.Version) } else { Write-Log '  git latest: unknown (network unavailable)' }
  }
  if (-not $SkipPs7) {
    $psPat = 'PowerShell-[\d.]+-win-' + $arch + '\.zip$'
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

if ($ResolveOnly -or $DryRun) {
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
Write-Log ('DONE. wrote=' + $Wrote + '. Next: apply the DSH profile patch (SKILL.md section 7), then restart DSH.')
if (-not $Wrote -and $offers.Count -eq 0) { Write-Log 'Nothing needed changing on this machine.' }
