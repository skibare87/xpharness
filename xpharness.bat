@echo off
REM Double-click launcher for xpharness.
title CLIPPY-XP
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -NoProfile -File harness.ps1
echo.
echo (harness exited)
pause
