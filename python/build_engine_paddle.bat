@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo   [可选] 原生 PaddleOCR 后端打包
echo   默认请优先用 build_engine.bat（PP-OCR 模型 + ONNX Runtime）
echo   本脚本需 Python 3.10 ~ 3.12（paddlepaddle 暂无 3.13 wheel）
echo ============================================================
echo.

set "PYCMD="
where py >nul 2>nul
if %errorlevel%==0 (
    for %%V in (3.12 3.11 3.10) do (
        if not defined PYCMD (
            py -%%V -c "import sys" >nul 2>nul
            if !errorlevel!==0 set "PYCMD=py -%%V"
        )
    )
)
if not defined PYCMD (
    echo [失败] 未找到 Python 3.10 ~ 3.12，请安装后再试。
    pause
    exit /b 1
)

echo [1/4] Python: %PYCMD%
if not exist ".venv_paddle\Scripts\python.exe" (
    %PYCMD% -m venv .venv_paddle
    if errorlevel 1 goto :fail
)
set "VPY=%CD%\.venv_paddle\Scripts\python.exe"

echo [2/4] 安装 paddlepaddle / paddleocr（体积较大，可能需要几分钟）...
"%VPY%" -m pip install --upgrade pip -q
"%VPY%" -m pip install -i https://pypi.org/simple paddlepaddle paddleocr pyinstaller
if errorlevel 1 goto :fail

echo [3/4] PyInstaller 打包...
REM 同样必须 --console 保留 stdin/stdout 管道。
"%VPY%" -m PyInstaller --noconfirm --clean --onedir --console ^
    --hide-console hide-early --name ocr_engine ^
    --collect-all paddleocr --collect-all paddlex --collect-all paddle ^
    --collect-binaries paddle ocr_engine.py
if errorlevel 1 goto :fail

echo [4/4] 部署到 windows\ocr_engine\ ...
set "TARGET=..\windows\ocr_engine"
if exist "%TARGET%" rmdir /s /q "%TARGET%"
mkdir "%TARGET%"
xcopy /E /I /Y /Q "dist\ocr_engine\*" "%TARGET%\" >nul
if errorlevel 1 goto :fail

echo.
echo [OK] 完成。注意：原生 PaddleOCR 首次运行会联网下载模型到用户目录；
echo      若要完全离线，请预下载模型到 python\models\ 并设置 PADDLEOCR_MODEL_DIR。
echo.
pause
exit /b 0

:fail
echo.
echo [失败] 原生 PaddleOCR 打包对环境要求较高，建议改用 build_engine.bat。
pause
exit /b 1
