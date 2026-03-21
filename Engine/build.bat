@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul 2>&1
set "PATH=C:\The Great Project\Engine\python;C:\The Great Project\Engine\python\Scripts;%PATH%"
cd /d "C:\The Great Project\Engine\godot-source"
echo === Starting Godot build ===
scons platform=windows target=editor arch=x86_64 d3d12=no -j12 > "C:\The Great Project\Engine\build_log.txt" 2>&1
set BUILD_EXIT=%ERRORLEVEL%
echo === Build exit code: %BUILD_EXIT% === >> "C:\The Great Project\Engine\build_log.txt" 2>&1
if %BUILD_EXIT%==0 (
    copy /Y "C:\The Great Project\Engine\godot-source\bin\godot.windows.editor.x86_64.exe" "C:\The Great Project\Engine\Godot_v4.6-stable_win64.exe" >nul
    copy /Y "C:\The Great Project\Engine\godot-source\bin\godot.windows.editor.x86_64.console.exe" "C:\The Great Project\Engine\Godot_v4.6-stable_win64_console.exe" >nul
    echo === Binaries copied === >> "C:\The Great Project\Engine\build_log.txt"
)
