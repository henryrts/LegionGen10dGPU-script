@echo off
setlocal

rem No encoded command, Base64 payload, or hidden script is used.
rem Use explicit Windows system paths so no executable is resolved from the current folder.
set "SYSTEM_FLTMC=%SystemRoot%\System32\fltmc.exe"
set "SYSTEM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

rem fltmc is used only to check whether this launcher already has administrator rights.
"%SYSTEM_FLTMC%" >nul 2>&1
if errorlevel 1 (
    rem Ask Windows to restart this same CMD file with administrator rights.
    set "LEGION_LAUNCHER=%~f0"
    "%SYSTEM_POWERSHELL%" -NoLogo -NoProfile -Command "Start-Process -FilePath $env:LEGION_LAUNCHER -Verb RunAs"
    exit /b
)

rem Run the readable PowerShell script stored in the same folder.
rem ExecutionPolicy Bypass applies only to this PowerShell process and changes no system policy.
"%SYSTEM_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Legion-Hybrid.ps1"
exit /b %errorlevel%
