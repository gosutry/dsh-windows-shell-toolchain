# verify.ps1 - confirm bash and PowerShell 7 are installed and reachable by name.
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh-tools' }
$fail = 0

$bash = Join-Path $Root 'git\bin\bash.exe'
if (Test-Path -LiteralPath $bash) {
  & $bash -c 'echo BASH=$BASH_VERSION; uname -s'
  if ($LASTEXITCODE -ne 0) { Write-Host '!! bash exited non-zero'; $fail++ }
} else { Write-Host ('!! missing ' + $bash); $fail++ }

$pwsh = Get-ChildItem -LiteralPath $Root -Directory -Filter 'PowerShell-*' -ErrorAction SilentlyContinue |
  ForEach-Object { Join-Path $_.FullName 'pwsh.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($pwsh) {
  $sig = Get-AuthenticodeSignature -LiteralPath $pwsh
  Write-Host ('pwsh signature: ' + $sig.Status)
  & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  if ($sig.Status -ne 'Valid') { Write-Host '!! pwsh signature not valid'; $fail++ }
} else { Write-Host '!! no PowerShell-* directory with pwsh.exe'; $fail++ }

$up = [Environment]::GetEnvironmentVariable('Path', 'User')
Write-Host ('USER Path: ' + $up)
if ($up -notmatch [regex]::Escape((Join-Path $Root 'git\bin'))) { Write-Host '!! USER Path lacks the git bin dir - bash will not resolve by name'; $fail++ }
if ($fail -gt 0) { Write-Host ('failures: ' + $fail); exit 1 }
Write-Host 'verify OK'
