@echo off
chcp 936 >nul
setlocal EnableDelayedExpansion
title ReadingApp Launcher

cd /d "%~dp0"

set "EXE=%~dp0build\windows\x64\runner\Debug\reading_app.exe"
set "FLUTTER="

echo.
echo ============================================================
echo   ReadingApp 启动验证工具
echo ============================================================
echo.
echo   [1] 直接启动(最快,用已编译的 exe)
echo   [2] 重新编译后启动(改了代码用这个)
echo   [3] 修复依赖并编译启动(项目换过位置/首次运行)
echo   [4] 仅修复依赖(flutter pub get)
echo   [5] 热重载开发模式(改代码即时生效,r 重载 / q 退出)
echo   [0] 退出
echo.
set /p choice=请选择 [0-5]:

if "%choice%"=="1" goto RUN_EXE
if "%choice%"=="2" goto BUILD_FLUTTER
if "%choice%"=="3" goto FIX_DEPS
if "%choice%"=="4" goto FIX_ONLY
if "%choice%"=="5" goto HOT_RELOAD
if "%choice%"=="0" goto END
echo 无效选择。
goto END

REM ===== 自动检测 Flutter(线性子程序) =====
:DETECT
for /f "delims=" %%i in ('where flutter.bat 2^>nul') do (
    if not defined FLUTTER set "FLUTTER=%%i"
)
if not defined FLUTTER if defined FLUTTER_HOME if exist "%FLUTTER_HOME%\bin\flutter.bat" set "FLUTTER=%FLUTTER_HOME%\bin\flutter.bat"
if not defined FLUTTER if exist "C:\flutter\bin\flutter.bat" set "FLUTTER=C:\flutter\bin\flutter.bat"
if not defined FLUTTER if exist "D:\flutter\bin\flutter.bat" set "FLUTTER=D:\flutter\bin\flutter.bat"
if not defined FLUTTER if exist "C:\src\flutter\bin\flutter.bat" set "FLUTTER=C:\src\flutter\bin\flutter.bat"
if not defined FLUTTER if exist "%LOCALAPPDATA%\Programs\flutter\bin\flutter.bat" set "FLUTTER=%LOCALAPPDATA%\Programs\flutter\bin\flutter.bat"
if not defined FLUTTER (
    echo [错误] 未找到 Flutter,请设置 FLUTTER_HOME 或把 flutter 的 bin 加入 PATH。
    goto :eof
)
echo [信息] 检测到 Flutter: %FLUTTER%
goto :eof

REM ===== 各分支入口 =====
:BUILD_FLUTTER
call :DETECT
if not defined FLUTTER goto END
echo.
echo 正在编译 Windows 桌面版...
call "%FLUTTER%" build windows --debug
if errorlevel 1 (
    echo [编译失败] 若提示缺少 native_assets 目录,先执行菜单 [3]。
    goto END
)
goto RUN_EXE

:FIX_ONLY
call :DETECT
if not defined FLUTTER goto END
echo.
echo 正在修复依赖...
call "%FLUTTER%" pub get
if errorlevel 1 (
    echo [错误] flutter pub get 失败。
    goto END
)
echo 依赖修复完成。
goto END

:FIX_DEPS
call :DETECT
if not defined FLUTTER goto END
echo.
echo [1/2] 修复依赖...
call "%FLUTTER%" pub get
if errorlevel 1 (
    echo [错误] flutter pub get 失败。
    goto END
)
echo [2/2] 依赖修复完成,开始编译...
call "%FLUTTER%" build windows --debug
if errorlevel 1 (
    echo [编译失败] 若提示缺少 native_assets 目录,手动建目录后重试。
    goto END
)
goto RUN_EXE

:HOT_RELOAD
call :DETECT
if not defined FLUTTER goto END
echo.
echo 正在打开热重载开发窗口...
echo   修改 lib 下的 Dart 文件后,在新窗口按 r 即时生效,R 重启,q 退出。
start "ReadingApp HotReload" cmd /k call "%FLUTTER%" run -d windows
goto END

:RUN_EXE
echo.
if not exist "%EXE%" (
    echo [错误] 找不到程序: %EXE%
    echo 请先执行菜单 [2] 或 [3] 编译。
    goto END
)
echo 正在启动应用: %EXE%
start "" "%EXE%"
goto END

:END
echo.
pause
