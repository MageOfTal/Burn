@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul 2>&1
set "PATH=C:\The Great Project\Engine\python;C:\The Great Project\Engine\python\Scripts;%PATH%"
cd /d "C:\The Great Project\Engine\godot-source"
echo === Starting Godot build ===
scons platform=windows target=editor arch=x86_64 d3d12=no -j12 > "C:\The Great Project\Engine\build_log.txt" 2>&1
echo === Build exit code: %ERRORLEVEL% === >> "C:\The Great Project\Engine\build_log.txt" 2>&1
