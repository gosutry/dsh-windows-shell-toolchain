[CmdletBinding()]
param([string]$DshExe = 'C:\Users\gsc\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe')
$ErrorActionPreference = 'Stop'
$p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
if ($p) { Write-Host ('stopping ' + $p.Count + ' process(es)'); $p | Stop-Process -Force; Start-Sleep -Seconds 4 }
if (-not (Test-Path -LiteralPath $DshExe)) { throw ('DSH not found: ' + $DshExe) }
Start-Process -FilePath $DshExe
Write-Host 'started. This window can be closed.'
