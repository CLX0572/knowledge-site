@echo off
REM COPY THIS FILE TO YOUR DESKTOP AND DOUBLE-CLICK IT.
REM Pure ASCII content; absolute hardcoded paths; NO Chinese chars anywhere in this file.
REM This file is intentionally 7-bit ASCII only so cmd.exe cannot misparse it.
setlocal
title Physics KB Deploy (Desktop Launcher)
echo DESKTOP_STUB_LAUNCHED_OK

REM -------------- ONLY EDIT THIS LINE IF YOU MOVE YOUR PROJECT FOLDER ---------------------
set "PROJ=C:\Users\Admin2\AppData\Roaming\TRAE SOLO CN\ModularData\ai-agent\work-mode-projects\6a6c95ede4950df239ca620a\knowledge-site"
REM -----------------------------------------------------------------------------------------

if NOT EXIST "%PROJ%\package.json" (
  echo FATAL: project root NOT FOUND: %PROJ%
  echo        Edit this bat file and fix the PROJ= line.
  pause
  exit /b 4
)
if NOT EXIST "%PROJ%\scripts\deploy_entry.ps1" (
  echo FATAL: scripts\deploy_entry.ps1 missing under %PROJ%
  pause
  exit /b 5
)
cd /d "%PROJ%"
echo Using project root: %CD%
where powershell >nul 2>&1
if errorlevel 1 (echo FATAL: powershell.exe not found in PATH & pause & exit /b 2)
echo Calling deploy_entry.ps1 ...
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%PROJ%\scripts\deploy_entry.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
echo deploy_entry.ps1 exited with code %EXITCODE%
echo DESKTOP_stub_pause_next_line
pause
endlocal
exit /b %EXITCODE%
