@echo off
rem 把项目根目录的最新代码同步进安卓工程（每次改完代码后运行一次）
setlocal
chcp 65001 >nul
set DST=%~dp0app\src\main\python\server
if not exist "%DST%" mkdir "%DST%"

set ROOT=%~dp0..\..
copy /y "%ROOT%\app.py" "%DST%\app.py" >nul
copy /y "%ROOT%\certs\cacert.pem" "%DST%\cacert.pem" >nul
xcopy /e /i /y "%ROOT%\reader" "%DST%\reader" >nul
xcopy /e /i /y "%ROOT%\web" "%DST%\web" >nul

echo 代码已同步到 packaging\android\app\src\main\python\server
echo 下一步：用 Android Studio 打开 packaging\android 构建 APK。
pause
