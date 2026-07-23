@echo off
REM Launches the iRacing X3D Tuning dashboard.
REM Uses Windows PowerShell 5.1 (built into Windows) - PowerShell 7 is NOT required.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Tuning-Menu.ps1"
if errorlevel 1 (
  echo.
  echo The dashboard exited with an error. Press any key to close.
  pause >nul
)
endlocal
