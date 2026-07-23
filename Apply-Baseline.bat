@echo off
REM Applies the full baseline in one pass, with a single admin prompt.
REM Uses Windows PowerShell 5.1 (built into Windows) - PowerShell 7 is NOT required.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-Baseline.ps1"
if errorlevel 1 (
  echo.
  echo Exited with an error. Press any key to close.
  pause >nul
)
endlocal
