@echo off
setlocal DisableDelayedExpansion
set "GAME=%~dp0."
set "LAUNCHER=%~dp0platform\steam\ue4ss\Mods\PBZRogue\StartIsolatedGame.ps1"
if not exist "%LAUNCHER%" (
    echo Endless Trials launcher is missing. Extract the complete ZIP into the game root.
    pause
    exit /b 1
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%LAUNCHER%" -GameRoot "%GAME%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
