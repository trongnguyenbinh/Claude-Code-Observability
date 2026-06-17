@echo off
REM Double-click to run on Windows. Calls PowerShell and bypasses the execution policy.
REM You can pass the token: install-otel.bat tok_xxxxx
setlocal
set TOKEN=%1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-otel.ps1" -Token "%TOKEN%"
echo.
pause
