@echo off
chcp 936 >nul
setlocal
title C盘磁盘清理工具
cd /d "%~dp0"

set "PS1=%~dp0清理C盘.ps1"
if not exist "%PS1%" (
    echo [错误] 未找到 清理C盘.ps1，请确认它和本文件在同一目录下。
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [提示] 当前不是管理员权限，系统级清理项会被自动跳过。
    echo        如需完整清理，请右键本文件选择"以管理员身份运行"。
    echo.
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
echo.
pause
