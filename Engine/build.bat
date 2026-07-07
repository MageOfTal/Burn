@echo off
REM ===========================================================
REM  Burn Royale - custom Godot 4.6 engine build
REM  Portable: derives all paths from this script's location
REM  (%~dp0 = the Engine\ folder this .bat lives in).
REM ===========================================================
setlocal enabledelayedexpansion

REM --- ENGINE_DIR = folder containing this script (no trailing slash) ---
set "ENGINE_DIR=%~dp0"
set "ENGINE_DIR=%ENGINE_DIR:~0,-1%"
set "SRC_DIR=%ENGINE_DIR%\godot-source"
set "LOG=%ENGINE_DIR%\build_log.txt"

REM --- Locate Visual Studio's vcvarsall.bat via vswhere (ships with VS Installer) ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSPATH="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
)
if defined VSPATH (
    call "%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul 2>&1
) else (
    echo WARNING: Visual Studio with C++ tools not found via vswhere.
    echo          Make sure vcvarsall has run / the MSVC compiler is on PATH.
)

REM --- Use bundled Python if present, otherwise rely on system Python + scons on PATH ---
if exist "%ENGINE_DIR%\python\Scripts" set "PATH=%ENGINE_DIR%\python;%ENGINE_DIR%\python\Scripts;%PATH%"

cd /d "%SRC_DIR%"
echo === Starting Godot build ===
scons platform=windows target=editor arch=x86_64 d3d12=no -j%NUMBER_OF_PROCESSORS% > "%LOG%" 2>&1
set BUILD_EXIT=%ERRORLEVEL%
echo === Build exit code: %BUILD_EXIT% === >> "%LOG%" 2>&1
if %BUILD_EXIT%==0 (
    call :try_copy "godot.windows.editor.x86_64.exe" "Godot_v4.6-stable_win64.exe"
    call :try_copy "godot.windows.editor.x86_64.console.exe" "Godot_v4.6-stable_win64_console.exe"
    echo === Binaries copied === >> "%LOG%"
)
echo === Build exit code: %BUILD_EXIT% (full log: %LOG%) ===
endlocal
goto :eof

:try_copy
copy /Y "%SRC_DIR%\bin\%~1" "%ENGINE_DIR%\%~2" >nul 2>&1
if errorlevel 1 (
    echo === SKIPPED %~2 (likely locked by running editor) === >> "%LOG%"
)
goto :eof
