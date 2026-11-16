@echo off
setlocal
if not defined ENDFIELD_PROJECT (
    echo Set ENDFIELD_PROJECT to the standalone Endfield project directory.
    exit /b 1
)
if not exist "%ENDFIELD_PROJECT%\debug_full_character.bat" (
    echo Endfield launcher was not found in ENDFIELD_PROJECT.
    exit /b 1
)
call "%ENDFIELD_PROJECT%\debug_full_character.bat" %*
exit /b %ERRORLEVEL%
