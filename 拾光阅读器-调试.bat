@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo 正在启动拾光阅读器…
echo （关闭此窗口即可结束服务）
if exist "C:\Users\EDY\.workbuddy\binaries\python\versions\3.13.12\python.exe" (
    "C:\Users\EDY\.workbuddy\binaries\python\versions\3.13.12\python.exe" app.py
) else (
    python app.py
)
pause
