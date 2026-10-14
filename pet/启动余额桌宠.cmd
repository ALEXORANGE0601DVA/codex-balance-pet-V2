@echo off
setlocal
set "SCRIPT=%~dp0start-pet.ps1"
set "PWSH="

if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe" set "PWSH=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if not defined PWSH where pwsh >nul 2>&1 && set "PWSH=pwsh.exe"
if not defined PWSH set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

"%PWSH%" -NoProfile -File "%SCRIPT%" %*
endlocal
