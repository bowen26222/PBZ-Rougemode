@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GmServer.ps1" %* -Open
if errorlevel 1 pause
