@echo off
setlocal
if not exist "%~dp0TokenRader.ps1" goto no_script
if not exist "%~dp0launcher\Start-TokenRader.ps1" goto no_script
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto no_host
rem Standard script entry: keep all system policies in force, with no EXE fallback.
rem The short bootstrap creates a console-free dashboard child, then exits.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -File "%~dp0launcher\Start-TokenRader.ps1"
exit /b %errorlevel%

:no_script
echo TokenRader.ps1 or launcher\Start-TokenRader.ps1 is missing.
exit /b 1

:no_host
echo Windows PowerShell was not found. No alternate host was attempted.
exit /b 1
