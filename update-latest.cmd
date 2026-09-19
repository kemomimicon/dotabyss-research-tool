@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-latest.ps1"
set "exitcode=%errorlevel%"
echo.
if not "%exitcode%"=="0" echo Update failed with exit code %exitcode%.
pause
exit /b %exitcode%
