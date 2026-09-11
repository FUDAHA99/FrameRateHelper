@echo off
rem FrameRateHelper diagnostics exporter (keep ASCII-only for codepage safety)
rem Runs UNELEVATED on purpose: this tool exists for the case where the app will
rem not open, and "elevation was refused" is one of those cases. Requiring admin
rem here would deadlock exactly the scenario it is meant to diagnose.
set "DFB_PS1=%~dp0scripts\export-diagnostics.ps1"
cd /d "%SystemRoot%\System32"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DFB_PS1%"
echo.
pause
