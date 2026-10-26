@echo off
REM Launches GamePerf - the frame-time logger + AI analyst (any game, monitor or VR).
REM Uses Windows PowerShell 5.1 (built into Windows) - PowerShell 7 is NOT required.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GamePerf.ps1"
if errorlevel 1 (
  echo.
  echo GamePerf exited with an error. Press any key to close.
  pause >nul
)
endlocal
