<#
  setup-tools.ps1 - install a real bash (PortableGit) and PowerShell 7 (portable) for DSH.
  No admin required. ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

  Everything machine-specific is a parameter:
    -Root         install root (default %LOCALAPPDATA%\dsh-tools)
    -GitVersion   asset version or 'latest' (default)
    -Ps7Version   asset version or 'latest' (default)
    -Mirror       optional download prefix tried before origin
    -ResolveOnly  print what would be downloaded, download nothing
    -Offline      skip downloads; require archives already under -Root
    -SkipGit / -SkipPs7 / -SkipPath
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$GitVersion = 'latest',
  [string]$Ps7Version = 'latest',
  [string]$Mirror = '',
  [switch]$ResolveOnly,
  [switch]$Offline,
  [switch]$SkipPath,
  [switch]$SkipGit,
  [switch]$SkipPs7
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh-tools' }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if (-not $ResolveOnly) { New-Item -ItemType Directory -Force -Path $Root | Out-Null }

function Get-Json([string]$url) {
  $headers = @{ 'User-Agent' = 'dsh-setup-tools' }
  try { return Invoke-RestMethod -Uri $url -UseBasicParsing -Headers $headers }
  catch { if ($Mirror) { return Invoke-RestMethod -Uri ($Mirror + $url) -UseBasicParsing -Headers $headers }; throw }
}

function Resolve-Asset([string]$repo, [string]$version, [string]$pattern) {
  if ($version -ne 'latest') { $rel = Get-Json ('https://api.github.com/repos/' + $repo + '/releases/tags/v' + $version) }
  else { $rel = Get-Json ('https://api.github.com/repos/' + $repo + '/releases/latest') }
  $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
  if (-not $asset) { throw ('no asset matching ' + $pattern + ' in release ' + $rel.tag_name) }
  $ver = $asset.name
  $ver = $ver -replace '^[A-Za-z]+-', ''
  $ver = $ver -replace '-(64-bit|arm64).*$', ''
  $ver = $ver -replace '-win-.*$', ''
  return @{ Version = $ver; Url = $asset.browser_download_url; Name = $asset.name }
}

function Get-Download([string]$url, [string]$dest) {
  $ok = $dest + '.ok'
  if ((Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $ok)) {
    Write-Host ('reuse ' + (Split-Path -Leaf $dest) + ' (previously verified complete)')
    return
  }
  if ($Offline) { throw ('offline mode: expected ' + $dest) }
  $part = $dest + '.part'
  $sources = @()
  if ($Mirror) { $sources += $Mirror }
  $sources += ''
  foreach ($m in $sources) {
    $label = if ($m -eq '') { 'origin' } else { $m }
    $u = if ($m -eq '') { $url } else { $m + $url }
    Write-Host ('downloading from ' + $label)
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    try {
      & curl.exe -L --fail --retry 2 --connect-timeout 20 -o $part $u
      if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -gt 1000000) {
        Move-Item -LiteralPath $part -Destination $dest -Force
        Set-Content -LiteralPath $ok -Value ((Get-Item -LiteralPath $dest).Length) -Encoding ASCII
        Write-Host ('ok ' + [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1) + ' MB')
        return
      }
    } catch { Write-Host ('source failed: ' + $label) }
  }
  if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  throw ('download failed: ' + $url + ' - if GitHub is slow here, pass -Mirror <prefix>')
}

$gitPat = 'PortableGit-[\d.]+-' + $(if ($arch -eq 'arm64') { 'arm64' } else { '64-bit' }) + '\.7z\.exe$'
$psPat = 'PowerShell-[\d.]+-win-' + $arch + '\.zip$'

$git = $null
$ps7 = $null
if (-not $SkipGit) { $git = Resolve-Asset 'git-for-windows/git' $GitVersion $gitPat; Write-Host ('bash source: ' + $git.Name) }
if (-not $SkipPs7) { $ps7 = Resolve-Asset 'PowerShell/PowerShell' $Ps7Version $psPat; Write-Host ('pwsh source: ' + $ps7.Name) }
if ($ResolveOnly) {
  if ($git) { Write-Host ('git url: ' + $git.Url) }
  if ($ps7) { Write-Host ('ps7 url: ' + $ps7.Url) }
  Write-Host 'resolve-only: nothing downloaded'
  exit 0
}

if (-not $SkipGit) {
  $gitExe = Join-Path $Root $git.Name
  $gitDir = Join-Path $Root 'git'
  if (-not (Test-Path -LiteralPath (Join-Path $gitDir 'bin\bash.exe'))) {
    Get-Download $git.Url $gitExe
    Write-Host 'extracting PortableGit...'
    if (Test-Path -LiteralPath $gitDir) { Remove-Item -LiteralPath $gitDir -Recurse -Force }
    & $gitExe ('-o' + $gitDir) '-y' | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $gitDir 'bin\bash.exe'))) { throw 'extraction produced no bin\bash.exe' }
  }
  $bashExe = Join-Path $gitDir 'bin\bash.exe'
  Write-Host ('bash: ' + $bashExe)
  & $bashExe -c 'echo BASH_VERSION=$BASH_VERSION; uname -s'
  if ($LASTEXITCODE -ne 0) { throw 'bash smoke test failed' }
}

if (-not $SkipPs7) {
  $ps7Dir = Join-Path $Root ('PowerShell-' + $ps7.Version)
  if (-not (Test-Path -LiteralPath (Join-Path $ps7Dir 'pwsh.exe'))) {
    $zip = Join-Path $Root $ps7.Name
    Get-Download $ps7.Url $zip
    if (Test-Path -LiteralPath $ps7Dir) { Remove-Item -LiteralPath $ps7Dir -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $ps7Dir -Force
  }
  $pwsh = Join-Path $ps7Dir 'pwsh.exe'
  $sig = Get-AuthenticodeSignature -LiteralPath $pwsh
  Write-Host ('pwsh signature: ' + $sig.Status + ' / ' + $sig.SignerCertificate.Subject)
  if ($sig.Status -ne 'Valid') { throw 'pwsh.exe signature is not valid - refusing to trust this download' }
  & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
}

if (-not $SkipPath) {
  $adds = @()
  if (-not $SkipGit) { $adds += (Join-Path $Root 'git\bin') }
  if (-not $SkipPs7) { $adds += (Join-Path $Root ('PowerShell-' + $ps7.Version)) }
  $up = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @($up -split ';' | Where-Object { $_ -ne '' })
  foreach ($a in $adds) {
    if ($parts -contains $a) { Write-Host ('user PATH already has ' + $a) }
    else {
      $parts += $a
      [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
      Write-Host ('added to user PATH: ' + $a)
    }
  }
  Write-Host 'NOTE: already-running processes keep their old PATH. Restart DSH.'
}

Write-Host ''
Write-Host 'DONE. Next: apply the DSH profile patch (SKILL.md section 5), then restart DSH.'
