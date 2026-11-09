@echo off
rem 局域网模式启动：让同一 WiFi 下的手机/平板用浏览器访问本机阅读器
rem 启动后窗口里会显示访问地址（也可在「我的」页查看）；Ctrl+C 停止
setlocal
chcp 65001 >nul
cd /d "%~dp0"
set SUDUGU_LAN=1
python app.py
pause
