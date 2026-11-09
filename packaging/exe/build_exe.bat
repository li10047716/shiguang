@echo off
rem 拾光阅读器 —— 打包 Windows exe
rem 需要：已安装 Python 3.9+ 并加入 PATH。产物在项目根目录 dist\拾光阅读器.exe
setlocal
chcp 65001 >nul
cd /d "%~dp0..\.."

echo [1/3] 安装打包依赖 (pyinstaller)...
python -m pip install --upgrade pyinstaller || goto :fail

echo [2/3] PyInstaller 打包中（首次需要几分钟）...
python -m PyInstaller --noconfirm --clean --onefile --windowed ^
  --name "拾光阅读器" ^
  --add-data "web;web" ^
  --add-data "reader;reader" ^
  packaging\exe\webview_app.py || goto :fail

echo [3/3] 完成！
echo   产物: dist\拾光阅读器.exe
echo   双击即可使用（需电脑装有 Edge 或 Chrome 浏览器，Win10/11 自带）。
echo   首次运行会在 exe 旁自动创建 data\ 目录存放书架与缓存。
pause
exit /b 0

:fail
echo.
echo 打包失败，请检查上方报错信息。
pause
exit /b 1
