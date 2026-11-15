<#
  restart-dsh.ps1 - stop and start DSH so a changed PATH takes effect.
  The executable is discovered at run time; no user name or drive is hard-coded. ASCII only.

  -DshExe PATH   override the discovery
  -ResolveOnly   print the discovered path and exit (no process is touched)

  PATH is re-read from the registry right before starting DSH. Start-Process inherits THIS
  process's environment block, so a caller launched before the PATH change (a long-lived host,
  or a terminal opened earlier) would otherwise hand DSH the stale block and bash would stay
  unfindable no matter how often it is restarted.
#>
[CmdletBinding()]
param(
  [string]$DshExe,
  [switch]$ResolveOnly
)
$ErrorActionPreference = 'Stop'

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

$exe = Resolve-DshExe -Override $DshExe
Write-Host ('DSH exe: ' + $exe)
if ($ResolveOnly) { Write-Host 'resolve-only: nothing stopped, nothing started.'; exit 0 }

$p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
if ($p) {
  Write-Host ('stopping ' + $p.Count + ' process(es)')
  $p | Stop-Process -Force
  Start-Sleep -Seconds 4
}
# Same trap as the deferred-environment case: the child inherits this block, not the registry.
# Rebuild machine+user PATH here so the restarted DSH sees what was written after this shell
# started. -UseNewEnvironment is not used: it wipes the rest of the block (PSModulePath, TEMP)
# instead of refreshing it, and the child fails to start on Windows PowerShell 5.1.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$freshPath = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
if ($freshPath) {
  $env:Path = $freshPath
  Write-Host ('PATH refreshed for the child: ' + ($freshPath.Length) + ' chars')
}
Start-Process -FilePath $exe
Write-Host 'started. This window can be closed.'
