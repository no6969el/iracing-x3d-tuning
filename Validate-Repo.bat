@echo off
cd /d "%~dp0"
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Validate-Repo.ps1"
pause
