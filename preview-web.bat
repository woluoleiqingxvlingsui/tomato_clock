@echo off
REM Tomato Clock web preview - double-click to run.
REM Real work (and all Chinese help text) lives in app\preview-web.ps1
REM To stop the server: press Ctrl+C in this window, or just close it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\preview-web.ps1"
pause
