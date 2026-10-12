@echo off
setlocal
if not exist "%~dp0TokenRader.ps1" goto no_script
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto no_host
rem Standard script entry: keep all system policies in force, with no EXE fallback.
rem CMD exits immediately; the PowerShell console is hidden, not the WPF window.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -File "%~dp0TokenRader.ps1"
exit /b %errorlevel%

:no_script
echo TokenRader.ps1 was not found next to this script.
exit /b 1

:no_host
echo Windows PowerShell was not found. No alternate host was attempted.
exit /b 1
