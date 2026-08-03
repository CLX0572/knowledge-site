@echo off
REM Physics KB deploy stub (project-root level). Do NOT rename. Do NOT add Chinese chars here.
REM Content of this file is 100% pure ASCII 7-bit. Saved as ANSI CP936 no BOM for cmd safety.
setlocal
title Physics KB Deploy
cd /d "%~dp0"
echo BAT_STUB_LAUNCHED_OK
where powershell >nul 2>&1
if errorlevel 1 (echo FATAL: powershell.exe not in PATH & pause & exit /b 2)
if NOT EXIST "%~dp0scripts\deploy_entry.ps1" (echo FATAL: scripts\deploy_entry.ps1 MISSING under "%~dp0" & pause & exit /b 3)
echo Calling deploy_entry.ps1 ...
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0scripts\deploy_entry.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
echo deploy_entry.ps1 exited with code %EXITCODE%
echo BAT_stub_pause_next_line
pause
endlocal
exit /b %EXITCODE%
