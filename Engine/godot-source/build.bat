@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" amd64
cd /d "C:\The Great Project\Engine\godot-source"
python -m SCons platform=windows target=editor d3d12=no -j%NUMBER_OF_PROCESSORS%
echo BUILD_EXIT_CODE=%ERRORLEVEL%
if %ERRORLEVEL% EQU 0 (
    echo Copying binaries to Engine folder...
    copy /Y "bin\godot.windows.editor.x86_64.exe" "C:\The Great Project\Engine\Godot_v4.6-stable_win64.exe"
    copy /Y "bin\godot.windows.editor.x86_64.console.exe" "C:\The Great Project\Engine\Godot_v4.6-stable_win64_console.exe"
    echo Deploy complete.
)
