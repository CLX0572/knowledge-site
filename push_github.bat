@echo off
REM ================================================================
REM   Physics KB GitHub Push - launch script (lives in project root)
REM   Double-click me to run. NO Chinese chars / NO fullwidth marks.
REM ================================================================
setlocal EnableExtensions
chcp 65001 >nul

echo.
echo [BAT] START push_github.bat
echo [BAT] Launcher dir      : %~dp0
echo [BAT] Scripts folder    : %~dp0scripts

if NOT EXIST "%~dp0package.json" (
  echo [FATAL] package.json not found next to this .bat file.
  echo         Put push_github.bat in the SAME folder as package.json, content/, .git/
  goto :END
)
if NOT EXIST "%~dp0scripts\simple_push.ps1" (
  echo [FATAL] scripts\simple_push.ps1 missing. Re-download or check folder.
  goto :END
)

powershell -NoProfile -ExecutionPolicy Bypass -NoLogo ^
  -File "%~dp0scripts\simple_push.ps1" %*

set "RC=%ERRORLEVEL%"
echo.
echo [BAT] simple_push.ps1 exit code: %RC%

:END
echo.
echo ================================================================
echo   Launcher done. This is the LAST LINE - window will not close.
echo   Close this window manually, or press any key.
echo ================================================================
pause
endlocal
