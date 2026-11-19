@echo off
rem Windows launcher for run-on-servers.ps1. Works from cmd, PowerShell or
rem Explorer without changing the PowerShell execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-on-servers.ps1" %*
exit /b %ERRORLEVEL%
