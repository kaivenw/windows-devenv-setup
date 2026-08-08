@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions

rem ===========================================================================
rem  Windows dev environment one-click installer -- launcher
rem
rem  KEEP THIS FILE PURE ASCII.
rem
rem  cmd.exe reads a .bat byte by byte and re-seeks the file position after
rem  every command it runs. Multi-byte characters (Chinese, box drawing) throw
rem  that position off, so cmd resumes from the middle of a line and tries to
rem  execute the fragment -- you get "'xxx' is not recognized as an internal
rem  or external command". It is intermittent and depends on line lengths,
rem  which makes it a nightmare to debug.
rem
rem  All user-facing Chinese lives in setup-devenv.ps1, which is UTF-8 with a
rem  BOM and handled properly by PowerShell.
rem ===========================================================================

title Windows DevEnv Setup

set "PS1=%~dp0setup-devenv.ps1"

if not exist "%PS1%" (
    echo.
    echo   [ERROR] setup-devenv.ps1 not found next to this file.
    echo   Keep the whole folder together and run again.
    echo.
    pause
    exit /b 1
)

rem --- already elevated? ---
net session >nul 2>&1
if not errorlevel 1 goto :RUN

echo.
echo   Requesting administrator privileges...
echo   Please click "Yes" on the UAC prompt.
echo.

rem Relaunch this .bat elevated. Start-Process quotes -FilePath correctly,
rem so paths containing spaces are fine.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
exit /b 0

:RUN
rem %USERPROFILE% is the real user here: UAC elevates the same account, and
rem setup-devenv.ps1 falls back to the explorer.exe owner if it is not.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InvokingUserProfile "%USERPROFILE%" %*

echo.
pause
