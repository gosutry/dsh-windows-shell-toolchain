@echo off
echo === restart DSH ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dsh.ps1"
echo exit code: %ERRORLEVEL%
pause