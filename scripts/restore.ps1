<#
  restore.ps1 - put the machine back to the state before this skill ran.

  The skill changes exactly three things:
    1. each profile cordis.patch.yml  (a marked block is appended)
    2. the user PATH                  (chosen bash/pwsh dirs moved to the front)
    3. the tool directory             (-Root, default %LOCALAPPDATA%\dsh-tools)

  Rollback is a RESTORE, not a partial undo: every recorded file is copied back byte for
  byte and the user PATH is set to its recorded value. That is why -Snapshot must run BEFORE
  the skill first changes anything; without a snapshot this script refuses to run rather than
  guessing which edits belonged to the skill.

  cordis.yml and package.json are never written by this skill and are never snapshotted.

  Usage:
    restore.ps1 -Snapshot                  record user PATH + copy each cordis.patch.yml
    restore.ps1 -DryRun                    show what would be restored
    restore.ps1                            restore files and PATH
    restore.ps1 -Uninstall                 also drop PATH entries under -Root
    restore.ps1 -Uninstall -DeleteTools    also delete the tool directory
    restore.ps1 -Restart                   restart DSH afterwards
#>
[CmdletBinding()]
param(
  [switch]$Snapshot,
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$DeleteTools,
  [switch]$Restart,
  [string]$StateDir,
  [string]$DshHome,
  [string[]]$Profiles,
  [string]$ToolsRoot,
  [string]$DshExe,
  [int]$KeepPrevs = 2
)

$ErrorActionPreference = 'Stop'

$localAppData = $env:LOCALAPPDATA
if (-not $localAppData -and $env:USERPROFILE) { $localAppData = Join-Path $env:USERPROFILE 'AppData\Local' }
if (-not $localAppData) { throw 'LOCALAPPDATA and USERPROFILE are both unset; pass -StateDir and -ToolsRoot' }
if (-not $StateDir) { $StateDir = Join-Path $localAppData 'dsh-windows-shell' }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path $localAppData 'dsh-tools' }
if (-not $DshHome) {
  if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
  else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
$ToolsRoot = $ToolsRoot.TrimEnd('\')

$backupDir = Join-Path $StateDir 'backup'
$manifest = Join-Path $backupDir 'manifest.json'

function Get-Sha([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-PatchFiles {
  $profilesRoot = Join-Path $DshHome 'profiles'
  if (-not (Test-Path -LiteralPath $profilesRoot)) {
    throw ('no profiles directory at ' + $profilesRoot + ' - pass -DshHome')
  }
  $names = @()
  if ($Profiles) { $names = $Profiles }
  else { $names = @(Get-ChildItem -LiteralPath $profilesRoot -Directory | Select-Object -ExpandProperty Name) }
  $files = @()
  foreach ($n in $names) {
    $p = Join-Path (Join-Path $profilesRoot $n) 'cordis.patch.yml'
    if (Test-Path -LiteralPath $p) { $files += $p }
  }
  return $files
}

function Split-PathText([string]$Text) {
  if (-not $Text) { return @() }
  return @(($Text -split ';') | Where-Object { $_ -ne '' })
}

function Get-UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }
function Set-UserPath([string]$Value) { [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }

function Remove-RootEntries([string[]]$Parts, [string]$Root) {
  $prefix = $Root.TrimEnd('\').ToLower() + '\'
  $kept = @()
  $dropped = @()
  foreach ($p in $Parts) {
    if ($p.TrimEnd('\').ToLower().StartsWith($prefix)) { $dropped += $p } else { $kept += $p }
  }
  return [pscustomobject]@{ Kept = $kept; Dropped = $dropped }
}

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
    if ($e -and $e.InstallLocation) {
      $cand = Join-Path $e.InstallLocation 'DeepSeek Harness.exe'
      if (Test-Path -LiteralPath $cand) { return $cand }
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

function Save-Snapshot {
  $files = @(Get-PatchFiles)
  if ($files.Count -eq 0) { throw ("no cordis.patch.yml found under " + $DshHome + "\profiles") }
  if (Test-Path -LiteralPath $backupDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = 'backup.prev-' + $stamp
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $StateDir $name)) { $n++; $name = 'backup.prev-' + $stamp + '-' + $n }
    Rename-Item -LiteralPath $backupDir -NewName $name
    Write-Host ("previous snapshot -> " + $name)
    $prevs = @(Get-ChildItem -LiteralPath $StateDir -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.PSIsContainer -and $_.Name -like 'backup.prev-*' } |
      Sort-Object LastWriteTime -Descending)
    for ($i = $KeepPrevs; $i -lt $prevs.Count; $i++) {
      Remove-Item -LiteralPath $prevs[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host ("pruned old snapshot: " + $prevs[$i].Name)
    }
  }
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
  $entries = @()
  $i = 0
  foreach ($f in $files) {
    $i++
    $bn = ('{0:D2}-{1}-{2}' -f $i, (Split-Path -Leaf (Split-Path -Parent $f)), (Split-Path -Leaf $f))
    $dst = Join-Path $backupDir $bn
    Copy-Item -LiteralPath $f -Destination $dst -Force
    $h = Get-Sha $f
    if ((Get-Sha $dst) -ne $h) { throw ('snapshot verify failed: ' + $f) }
    $entries += [pscustomobject]@{ Source = $f; Backup = $bn; Sha256 = $h; Bytes = (Get-Item -LiteralPath $f).Length }
    Write-Host ("saved " + $f)
  }
  $meta = [pscustomobject]@{
    CreatedAt = (Get-Date).ToString('o')
    UserPath = Get-UserPath
    ToolsRoot = $ToolsRoot
    Files = $entries
  }
  $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
  Write-Host ""
  Write-Host ("snapshot done: " + $entries.Count + " file(s) + user PATH -> " + $backupDir)
  exit 0
}

# ---------------------------------------------------------------------------
if ($Snapshot) { Save-Snapshot }

if (-not (Test-Path -LiteralPath $manifest)) {
  throw ("no snapshot at " + $manifest + " ; run -Snapshot BEFORE the skill changes anything")
}
$meta = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$fail = 0

Write-Host ""
Write-Host '=== files ==='
foreach ($f in $meta.Files) {
  if ((Split-Path -Leaf $f.Source) -ne 'cordis.patch.yml') {
    Write-Host ("  skip (never written by this skill): " + $f.Source)
    continue
  }
  $bak = Join-Path $backupDir $f.Backup
  if ((Get-Sha $bak) -ne $f.Sha256) { Write-Host ("  !! snapshot corrupted: " + $bak); $fail++; continue }
  $cur = Get-Sha $f.Source
  $state = if ($cur -eq $f.Sha256) { 'SAME   ' } elseif ($null -eq $cur) { 'MISSING' } else { 'CHANGED' }
  Write-Host ("  [" + $state + "] " + $f.Source)
  if ($DryRun -or $cur -eq $f.Sha256) { continue }
  Copy-Item -LiteralPath $bak -Destination $f.Source -Force
  if ((Get-Sha $f.Source) -ne $f.Sha256) { Write-Host ("  !! post-restore verify failed: " + $f.Source); $fail++ }
}

Write-Host ""
Write-Host '=== user PATH ==='
$current = Get-UserPath
$targetParts = Split-PathText $meta.UserPath
$dropped = @()
if ($Uninstall) {
  $r = Remove-RootEntries $targetParts $ToolsRoot
  $targetParts = $r.Kept
  $dropped = $r.Dropped
}
foreach ($d in $dropped) { Write-Host ("  drop " + $d) }
$newPath = ($targetParts -join ';')
if ($current -eq $newPath) {
  Write-Host '  already matches the snapshot'
} elseif ($DryRun) {
  Write-Host ("  would set: " + $newPath)
} else {
  Set-UserPath $newPath
  if ((Get-UserPath) -eq $newPath) { Write-Host '  written and read back OK' } else { Write-Host '  !! write failed'; $fail++ }
}

if ($Uninstall) {
  Write-Host ""
  Write-Host '=== tool directory ==='
  if (-not (Test-Path -LiteralPath $ToolsRoot)) {
    Write-Host ("  already absent: " + $ToolsRoot)
  } else {
    $items = @(Get-ChildItem -LiteralPath $ToolsRoot | Select-Object -ExpandProperty FullName)
    Write-Host ("  " + $ToolsRoot)
    foreach ($it in $items) { Write-Host ("    " + $it) }
    if (-not $DeleteTools) {
      Write-Host '  left in place; re-run with -DeleteTools to remove it'
    } elseif ($DryRun) {
      Write-Host '  would delete the directory above'
    } else {
      $resolved = (Resolve-Path -LiteralPath $ToolsRoot).Path.TrimEnd('\')
      $allowed = @((Join-Path $localAppData 'dsh-tools').TrimEnd('\'), $ToolsRoot.TrimEnd('\'))
      if ($allowed -notcontains $resolved) { throw ('refusing to delete unexpected path: ' + $resolved) }
      try {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        Write-Host '  deleted'
      } catch {
        Write-Host ("  delete failed: " + $_.Exception.Message)
        Write-Host "  (a shell from that directory may still be running; close it and retry)"
        $fail++
      }
    }
  }
}

if ($Restart -and -not $DryRun) {
  Write-Host ""
  Write-Host '=== restart ==='
  $exe = Resolve-DshExe -Override $DshExe
  Write-Host ("  dsh exe: " + $exe)
  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
  if ($running) { Write-Host '  stopping...'; $running | Stop-Process -Force; Start-Sleep -Seconds 4 }
  Start-Process -FilePath $exe
  Write-Host '  started'
}

if ($DryRun) { Write-Host ("dry-run: nothing written"); if ($fail) { exit 1 } else { exit 0 } }
if ($fail -gt 0) { Write-Host ("failures: " + $fail); exit 1 }
Write-Host 'restore complete: files and user PATH are back to the snapshot.'
exit 0
