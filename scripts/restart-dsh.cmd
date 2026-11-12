@echo off
echo === restart DSH ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dsh.ps1" %*
set RC=%ERRORLEVEL%
echo exit code: %RC%
if "%~1"=="" pause
exit /b %RC%
