@echo off
setlocal enabledelayedexpansion
rem ===========================================================================
rem 水质检测仪助手 0.6.6 一键打包（在普通 Windows 终端运行，勿在受限终端中运行）
rem   产物输出到 dist\ ：
rem     water_quality_detector_assistant_0.6.6_arm64.apk
rem     water_quality_detector_assistant_0.6.6_windows_x64.zip
rem ===========================================================================
cd /d "%~dp0.."
set VERSION=0.6.6
set DIST=%CD%\dist
if not exist "%DIST%" mkdir "%DIST%"

echo.
echo [1/4] 拉取依赖 ...
call flutter pub get
if errorlevel 1 goto :failed

echo.
echo [2/4] 构建 Android arm64 release APK ...
call flutter build apk --release --target-platform android-arm64 --split-per-abi
if errorlevel 1 goto :failed
set APK_SRC=build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
if not exist "%APK_SRC%" set APK_SRC=build\app\outputs\flutter-apk\app-release.apk
if not exist "%APK_SRC%" (
  echo 未找到 APK 产物，请检查 build\app\outputs\flutter-apk\ 目录
  goto :failed
)
copy /Y "%APK_SRC%" "%DIST%\water_quality_detector_assistant_%VERSION%_arm64.apk" >nul
echo    APK 已复制

echo.
echo [3/4] 构建 Windows x64 release ...
call flutter build windows --release
if errorlevel 1 goto :failed
set WIN_DIR=build\windows\x64\runner\Release
if not exist "%WIN_DIR%\water_quality_detector_assistant.exe" (
  echo 未找到 Windows 可执行文件
  goto :failed
)
set ZIP_OUT=%DIST%\water_quality_detector_assistant_%VERSION%_windows_x64.zip
if exist "%ZIP_OUT%" del /F /Q "%ZIP_OUT%"
powershell -NoProfile -Command "Compress-Archive -Path '%WIN_DIR%\*' -DestinationPath '%ZIP_OUT%' -CompressionLevel Optimal"
if errorlevel 1 goto :failed
echo    Windows 压缩包已生成

echo.
echo [4/4] 产物清单
dir /B "%DIST%\water_quality_detector_assistant_%VERSION%*"
echo.
echo 如需发布到 Gitee：先设置 GITEE_TOKEN，再运行 python scripts\gitee_release.py
goto :eof

:failed
echo.
echo 打包失败，请查看上方错误输出。
exit /b 1
