@echo off
rem ============================================================
rem NovelCraft Windows 便携版一键构建脚本
rem 前置要求（只装一次）：
rem   1. Flutter SDK（含 Windows 桌面支持）：https://docs.flutter.dev/get-started/install/windows
rem   2. Visual Studio 2022（勾选「使用 C++ 的桌面开发」工作负载）
rem 用法：双击本文件，或在开发者命令行中运行。
rem 产物：build\windows\x64\runner\Release\ → 整个文件夹即为便携版，
rem       压缩成 zip 拷到任何 Windows x64 机器解压即用（免安装）。
rem ============================================================
chcp 65001 >nul
setlocal

where flutter >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 flutter 命令，请先安装 Flutter SDK 并加入 PATH。
    pause & exit /b 1
)

cd /d "%~dp0.."

echo [1/2] flutter doctor 体检...
flutter doctor | findstr /C:"Visual Studio" /C:"Flutter"
echo.
echo [2/2] 开始构建 Windows Release...
flutter build windows --release
if errorlevel 1 (
    echo [错误] 构建失败，请检查上方日志（通常是缺 VS C++ 工作负载）。
    pause & exit /b 1
)

echo.
echo 构建成功！便携版目录：
echo   %cd%\build\windows\x64\runner\Release
echo 把该目录整体压缩为 zip，即可在任何 Windows x64 机器解压运行。
pause
