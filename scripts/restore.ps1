<#
  restore.ps1 - snapshot and byte-exact restore of DSH profile config files, plus rollback
  of the user PATH change made by setup-tools.ps1. ASCII only.

  Usage:
    restore.ps1 -Snapshot            create a snapshot (do this BEFORE any change)
    restore.ps1 -DryRun              compare only, write nothing
    restore.ps1                      restore files from the snapshot
    restore.ps1 -RestorePath         also restore the USER Path environment variable
    restore.ps1 -Restart             restore, then restart DSH
    restore.ps1 -Uninstall           restore config + user PATH, print what is left to remove
    restore.ps1 -Uninstall -DeleteTools   also delete the managed tool directories

  The DSH executable is discovered at run time (running process -> uninstall registry entry ->
  Start Menu shortcut -> default install path), so it works on any user name or install drive.
#>
[CmdletBinding()]
param(
  [switch]$Snapshot,
  [switch]$DryRun,
  [switch]$RestorePath,
  [switch]$Restart,
  [switch]$Uninstall,
  [switch]$DeleteTools,
  [string]$StateDir,
  [string]$DshHome,
  [string[]]$Profiles,
  [string]$Extra = '',
  [string]$DshExe,
  [string]$ToolsRoot
)

$ErrorActionPreference = 'Stop'
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-shell' }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path $env:LOCALAPPDATA 'dsh-tools' }
if (-not $DshHome) { if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' } }
$backupDir = Join-Path $StateDir 'backup'
$manifest = Join-Path $backupDir 'manifest.json'

function Resolve-DshExe {
  param([string]$Override)
  if ($Override) {
    if (Test-Path -LiteralPath $Override) { return $Override }
    throw ('DSH exe not found at -DshExe ' + $Override)
  }
  $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
    Where-Object { try { $null -ne $_.Path } catch { $false } } | Select-Object -First 1
  if ($p) { return $p.Path }

  foreach ($k in @(
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $e = Get-ItemProperty $k -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -like '*DeepSeek*' } | Select-Object -First 1
    if ($e) {
      $cand = $null
      if ($e.InstallLocation) { $cand = Join-Path $e.InstallLocation 'DeepSeek Harness.exe' }
      if ((-not $cand -or -not (Test-Path -LiteralPath $cand)) -and $e.DisplayIcon) {
        $cand = ($e.DisplayIcon -split ',')[0].Trim('"')
      }
      if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
    }
  }

  foreach ($root in @($env:APPDATA, $env:ProgramData)) {
    $lnk = Join-Path $root 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness.lnk'
    if (Test-Path -LiteralPath $lnk) {
      $t = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
      if ($t -and (Test-Path -LiteralPath $t)) { return $t }
    }
  }

  $def = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
  if (Test-Path -LiteralPath $def) { return $def }
  throw 'DSH exe not found (process, registry, shortcut, default path). Pass -DshExe <path>.'
}

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
$doPath = $RestorePath -or $Uninstall
if ($doPath) {
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

if ($Uninstall) {
  Write-Host ''
  Write-Host '=== uninstall ==='
  if (-not (Test-Path -LiteralPath $ToolsRoot)) {
    Write-Host ('tool directory already absent: ' + $ToolsRoot)
  } else {
    $items = @(Get-ChildItem -LiteralPath $ToolsRoot | Select-Object -ExpandProperty FullName)
    Write-Host ('tool directory: ' + $ToolsRoot)
    foreach ($it in $items) { Write-Host ('  ' + $it) }
    if (-not $DeleteTools) {
      Write-Host 'Left in place. Re-run with -DeleteTools to remove the directory above.'
    } else {
      $resolved = (Resolve-Path -LiteralPath $ToolsRoot).Path.TrimEnd('\')
      $allowed = @(
        (Join-Path $env:LOCALAPPDATA 'dsh-tools').TrimEnd('\'),
        $ToolsRoot.TrimEnd('\'))
      if ($allowed -notcontains $resolved) { throw ('refusing to delete unexpected path: ' + $resolved) }
      Write-Host ('deleting ' + $resolved)
      Remove-Item -LiteralPath $resolved -Recurse -Force
      if (Test-Path -LiteralPath $resolved) { throw ('delete failed: ' + $resolved) }
      Write-Host 'deleted.'
    }
  }
  Write-Host 'Restart DSH so the restored PATH and profile take effect.'
}

if ($Restart) {
  $exe = Resolve-DshExe -Override $DshExe
  Write-Host ('DSH exe: ' + $exe)
  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
  if ($running) { Write-Host 'stopping DSH...'; $running | Stop-Process -Force; Start-Sleep -Seconds 4 }
  Start-Process -FilePath $exe
  Write-Host 'started.'
}
exit 0
