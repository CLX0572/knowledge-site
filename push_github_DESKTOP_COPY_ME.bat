@echo off
REM ================================================================
REM   COPY THIS FILE TO YOUR DESKTOP AND DOUBLE-CLICK IT.
REM   Path is HARDCODED so cmd.exe has NO CHANCE to mis-resolve.
REM   NO Chinese chars anywhere -> avoids CP936 eat-first-char bug.
REM ================================================================
setlocal EnableExtensions
chcp 65001 >nul

REM --- HARDCODED PROJECT ROOT (EDIT ONLY IF YOU MOVE THE PROJECT) ---
set "ROOT=E:\TRAE SOLO CN\app\knowledge-site"
set "PS1=%ROOT%\scripts\simple_push.ps1"

echo.
echo [DESKTOP BAT] Physics KB GitHub Push (desktop launcher)
echo [DESKTOP BAT] Using project root:
echo                %ROOT%
echo [DESKTOP BAT] Calling script:
echo                %PS1%

if NOT EXIST "%ROOT%\package.json" (
  echo.
  echo [FATAL] package.json MISSING in ROOT.
  echo         Edit this .bat file and fix the ROOT variable.
  echo         Expected to find package.json AT:
  echo           %ROOT%\package.json
  goto :END
)
if NOT EXIST "%PS1%" (
  echo.
  echo [FATAL] simple_push.ps1 MISSING at:
  echo           %PS1%
  echo         Re-download from knowledge-site\scripts\
  goto :END
)

echo [DESKTOP BAT] Launching PowerShell ...

powershell -NoProfile -ExecutionPolicy Bypass -NoLogo ^
  -File "%PS1%" %*

set "RC=%ERRORLEVEL%"
echo.
echo [DESKTOP BAT] simple_push.ps1 exit code: %RC%

:END
echo.
echo ================================================================
echo   DESKTOP launcher done. Last line of BAT = always pause below.
echo   Close this window manually, or press ANY key.
echo ================================================================
pause
endlocal
