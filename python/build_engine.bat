@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo   水质检测仪助手 - Windows 本地 OCR 引擎一键打包
echo   后端: PaddleOCR 官方 PP-OCR 模型 (RapidOCR / ONNX Runtime)
echo ============================================================
echo.

REM 选一个 3.10~3.13 的 Python；优先 py 启动器。
set "PYCMD="
where py >nul 2>nul
if %errorlevel%==0 (
    for %%V in (3.12 3.11 3.13 3.10) do (
        if not defined PYCMD (
            py -%%V -c "import sys" >nul 2>nul
            if !errorlevel!==0 set "PYCMD=py -%%V"
        )
    )
)
if not defined PYCMD set "PYCMD=python"

echo [1/4] Python: %PYCMD%
if not exist ".venv_ocr\Scripts\python.exe" (
    %PYCMD% -m venv .venv_ocr
    if errorlevel 1 goto :fail
)
set "VPY=%CD%\.venv_ocr\Scripts\python.exe"

echo [2/4] 安装依赖（仅首次需联网，约 1-3 分钟）...
"%VPY%" -m pip install --upgrade pip -q
"%VPY%" -m pip install -i https://pypi.org/simple -r requirements.txt
if errorlevel 1 goto :fail

echo [3/4] PyInstaller 打包为独立目录（模型内置，免装 Python）...
REM 必须用 --console 保留 stdin/stdout 管道；--hide-console 在启动后隐藏黑框。
REM --noconsole 会让 sys.stdout 失效，导致 Flutter 收不到任何 JSON。
"%VPY%" -m PyInstaller --noconfirm --clean --onedir --console ^
    --hide-console hide-early --name ocr_engine ^
    --collect-all rapidocr_onnxruntime --collect-all onnxruntime ^
    --hidden-import cv2 --hidden-import numpy ocr_engine.py
if errorlevel 1 goto :fail

echo [4/4] 部署到 windows\ocr_engine\（CMake 构建时自动随应用分发）...
set "TARGET=..\windows\ocr_engine"
if exist "%TARGET%" rmdir /s /q "%TARGET%"
mkdir "%TARGET%"
xcopy /E /I /Y /Q "dist\ocr_engine\*" "%TARGET%\" >nul
if errorlevel 1 goto :fail

echo.
echo [OK] 完成: windows\ocr_engine\ocr_engine.exe
echo      之后直接执行 flutter build windows，引擎会自动拷到应用 exe 同级，
echo      应用内无需配置任何路径即可离线识别。
echo.
pause
exit /b 0

:fail
echo.
echo [失败] 请查看上方错误信息后重试。
pause
exit /b 1
