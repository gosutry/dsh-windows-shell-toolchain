<#
  restore.ps1 - snapshot and byte-exact restore of DSH profile config files.
  Targets are auto-discovered under <DSH home>\profiles\*; override with -Profiles.

  Usage:
    restore.ps1 -Snapshot            create a snapshot (do this BEFORE any change)
    restore.ps1 -DryRun              compare only, write nothing
    restore.ps1                      restore files from the snapshot
    restore.ps1 -RestorePath         also restore the USER Path environment variable
    restore.ps1 -Restart             restore, then restart DSH
#>
[CmdletBinding()]
param(
  [switch]$Snapshot,
  [switch]$DryRun,
  [switch]$RestorePath,
  [switch]$Restart,
  [string]$StateDir,
  [string]$DshHome,
  [string[]]$Profiles,
  [string]$Extra = ''
)

$ErrorActionPreference = 'Stop'
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-shell' }
if (-not $DshHome) { if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' } }
$backupDir = Join-Path $StateDir 'backup'
$manifest = Join-Path $backupDir 'manifest.json'

$profileRoot = Join-Path $DshHome 'profiles'
$names = @()
if ($Profiles) { $names = $Profiles }
elseif (Test-Path -LiteralPath $profileRoot) { $names = Get-ChildItem -LiteralPath $profileRoot -Directory | Select-Object -ExpandProperty Name }

$targets = @()
foreach ($n in $names) {
  foreach ($f in @('cordis.patch.yml', 'cordis.yml', 'package.json')) {
    $p = Join-Path (Join-Path $profileRoot $n) $f
    if (Test-Path -LiteralPath $p) { $targets += $p }
  }
}
if ($Extra) { foreach ($e in ($Extra -split ';')) { if ($e.Trim()) { $targets += $e.Trim() } } }
if ($targets.Count -eq 0) { throw ('no config files found under ' + $profileRoot + ' - pass -Profiles or -Extra') }

function Get-Sha([string]$p) { if (Test-Path -LiteralPath $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $null } }

if ($Snapshot) {
  if (Test-Path -LiteralPath $backupDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Rename-Item -LiteralPath $backupDir -NewName ('backup.prev-' + $stamp)
    Write-Host ('previous snapshot -> backup.prev-' + $stamp)
  }
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
  $entries = @()
  $i = 0
  foreach ($t in $targets) {
    $i++
    $bn = ('{0:D2}-{1}' -f $i, (Split-Path -Leaf (Split-Path -Parent $t)))
    $bn = $bn + '-' + (Split-Path -Leaf $t)
    $dst = Join-Path $backupDir $bn
    Copy-Item -LiteralPath $t -Destination $dst -Force
    $h = Get-Sha $t
    if ((Get-Sha $dst) -ne $h) { throw ('snapshot verify failed: ' + $t) }
    $entries += [pscustomobject]@{ Source = $t; Backup = $bn; Sha256 = $h; Bytes = (Get-Item -LiteralPath $t).Length }
    Write-Host ('saved ' + $t)
  }
  $meta = [pscustomobject]@{
    CreatedAt = (Get-Date).ToString('o')
    UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    Files = $entries
  }
  $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
  Write-Host ''
  Write-Host ('snapshot done: ' + $entries.Count + ' files -> ' + $backupDir)
  exit 0
}

if (-not (Test-Path -LiteralPath $manifest)) { throw ('no snapshot at ' + $manifest + ' ; run -Snapshot first') }
$meta = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json

$fail = 0
if ($RestorePath) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($DryRun) { Write-Host ('USER Path current : ' + $cur); Write-Host ('USER Path snapshot: ' + $meta.UserPath) }
  elseif ($cur -eq $meta.UserPath) { Write-Host 'USER Path already matches snapshot.' }
  else {
    [Environment]::SetEnvironmentVariable('Path', $meta.UserPath, 'User')
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $meta.UserPath) { Write-Host 'USER Path restored.' }
    else { Write-Host '!! USER Path restore failed.'; $fail++ }
  }
}

foreach ($f in $meta.Files) {
  $cur = Get-Sha $f.Source
  $bak = Join-Path $backupDir $f.Backup
  if ((Get-Sha $bak) -ne $f.Sha256) { Write-Host ('!! snapshot corrupted: ' + $bak); $fail++; continue }
  $state = if ($cur -eq $f.Sha256) { 'SAME   ' } elseif ($null -eq $cur) { 'MISSING' } else { 'CHANGED' }
  Write-Host ('[' + $state + '] ' + $f.Source)
  if ($DryRun -or $cur -eq $f.Sha256) { continue }
  Copy-Item -LiteralPath $bak -Destination $f.Source -Force
  if ((Get-Sha $f.Source) -ne $f.Sha256) { Write-Host ('!! post-restore verify failed: ' + $f.Source); $fail++ }
}

if ($DryRun) { Write-Host 'DryRun finished, nothing written.'; if ($fail) { exit 1 } else { exit 0 } }
if ($fail -gt 0) { Write-Host ('failures: ' + $fail); exit 1 }
Write-Host 'Restore complete, all hashes verified.'

if ($Restart) {
  $exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
  if ($running) { Write-Host 'stopping DSH...'; $running | Stop-Process -Force; Start-Sleep -Seconds 4 }
  if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe; Write-Host 'started.' }
  else { Write-Host ('!! DSH exe not found at ' + $exe + ' - start it manually') }
}
exit 0
