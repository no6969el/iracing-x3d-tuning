@echo off
setlocal
cd /d "%~dp0"
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0Small-Tuning-Menu.ps1"
