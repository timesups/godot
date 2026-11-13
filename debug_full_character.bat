@echo off
setlocal
cd /d "%~dp0"
set "GODOT_EXE=%~dp0bin\godot.windows.editor.x86_64.console.exe"
set "EVIDENCE=%~dp0.renderdoc-analysis\endfield-frame37917\gbuffer-materials"
set "KEEP_OPEN=--keep-open"
if "%~1"=="--smoke" set "KEEP_OPEN="
if not exist "%GODOT_EXE%" (
    echo Build the Windows editor first.
    exit /b 1
)
"%~dp0.venv\Scripts\python.exe" "%~dp0tests\rendering\custom_forward\prepare_character.py" "%EVIDENCE%"
if errorlevel 1 exit /b 1
"%GODOT_EXE%" --path "%~dp0tests\rendering\custom_forward" --rendering-method custom_forward --rendering-driver vulkan --script res://full_character.gd -- --evidence="%EVIDENCE%" %KEEP_OPEN% %*
exit /b %ERRORLEVEL%
