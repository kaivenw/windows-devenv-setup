@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions

title Windows 开发环境一键安装

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%setup-devenv.ps1"
set "ORIG_PROFILE=%USERPROFILE%"

if not exist "%PS1%" (
    echo.
    echo   [错误] 找不到 setup-devenv.ps1，请保持本 bat 与它在同一目录。
    echo.
    pause
    exit /b 1
)

rem ── 检查管理员权限，没有就带上原始用户主目录重新提权启动 ──
net session >nul 2>&1
if not errorlevel 1 goto :RUN

echo.
echo   正在请求管理员权限，请在弹出的 UAC 窗口点"是"...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%PS1%','-InvokingUserProfile','%ORIG_PROFILE%')"
exit /b 0

:RUN
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InvokingUserProfile "%ORIG_PROFILE%" %*
echo.
echo   ────────────────────────────────────────────────
echo   安装流程结束。请关闭本窗口，重新打开一个新的终端。
echo   ────────────────────────────────────────────────
echo.
pause
