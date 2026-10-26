@echo off
REM Launches the free VR resolution preview, or explains where the Windows build goes.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-VrResPreview.ps1"
endlocal
