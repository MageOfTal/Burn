@echo off
REM ===========================================================
REM  Burn Royale - build from inside godot-source\
REM  Portable: paths derived from this script's location.
REM  (Prefer Engine\build.bat one level up; this is the
REM   in-tree convenience variant.)
REM ===========================================================
setlocal

REM --- SRC_DIR = this script's folder; ENGINE_DIR = its parent ---
set "SRC_DIR=%~dp0"
set "SRC_DIR=%SRC_DIR:~0,-1%"
for %%i in ("%SRC_DIR%\..") do set "ENGINE_DIR=%%~fi"

REM --- Locate Visual Studio's vcvarsall.bat via vswhere ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSPATH="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
)
if defined VSPATH (
    call "%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat" amd64
) else (
    echo WARNING: Visual Studio with C++ tools not found via vswhere.
)

cd /d "%SRC_DIR%"
python -m SCons platform=windows target=editor d3d12=no -j%NUMBER_OF_PROCESSORS%
echo BUILD_EXIT_CODE=%ERRORLEVEL%
if %ERRORLEVEL% EQU 0 (
    echo Copying binaries to Engine folder...
    copy /Y "bin\godot.windows.editor.x86_64.exe" "%ENGINE_DIR%\Godot_v4.6-stable_win64.exe"
    copy /Y "bin\godot.windows.editor.x86_64.console.exe" "%ENGINE_DIR%\Godot_v4.6-stable_win64_console.exe"
    echo Deploy complete.
)
endlocal
