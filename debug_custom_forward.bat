@echo off
setlocal
rem Paths are relative to this BAT, so launching from Explorer also works.
set "GODOT_ROOT=%~dp0"
set "GODOT_EXE=%GODOT_ROOT%bin\godot.windows.editor.dev.x86_64.console.exe"
if not exist "%GODOT_EXE%" set "GODOT_EXE=%GODOT_ROOT%bin\godot.windows.editor.x86_64.console.exe"
set "LUT_FILE=%GODOT_ROOT%.renderdoc-analysis\endfield-frame37917\lut.res"
set "LOG_FILE=%GODOT_ROOT%.renderdoc-analysis\debug-custom-forward.log"
set "KEEP_OPEN=--keep-open"
if /i "%~1"=="--smoke" set "KEEP_OPEN="

if not exist "%GODOT_EXE%" (
    echo ERROR: Godot editor executable not found. Build the engine first.
    set "RESULT=1"
    goto finish
)
if not exist "%LUT_FILE%" (
    echo ERROR: Capture LUT not found:
    echo "%LUT_FILE%"
    echo Run the post_process.gd capture test to generate lut.res.
    set "RESULT=1"
    goto finish
)

echo Starting Custom Forward with captured Bloom and LUT.
echo Executable: "%GODOT_EXE%"
echo Log: "%LOG_FILE%"
echo Close the game window to stop. Use --case=taa or --case=msaa for other inputs.
echo For C++ breakpoints, attach Visual Studio to the running Godot process.
echo.
"%GODOT_EXE%" --path "%GODOT_ROOT%tests\rendering\custom_forward" --script res://smoke.gd --rendering-method custom_forward --rendering-driver vulkan --debug --verbose --log-file "%LOG_FILE%" --fixed-fps 60 -- --post-lut="%LUT_FILE%" %KEEP_OPEN% %*
set "RESULT=%ERRORLEVEL%"

:finish
echo.
echo Godot exited with code %RESULT%.
if /i not "%~1"=="--smoke" pause
exit /b %RESULT%
