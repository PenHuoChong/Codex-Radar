@echo off
setlocal
if not exist "%~dp0TokenRader.exe" goto no_launcher
rem Detach the GUI launcher; do not keep CMD alive for the dashboard lifetime.
start "" "%~dp0TokenRader.exe"
exit /b %errorlevel%

:no_launcher
echo TokenRader.exe was not found. Run Build.ps1 to build the GUI launcher.
exit /b 1
