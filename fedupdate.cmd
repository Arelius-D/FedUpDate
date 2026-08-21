@echo off
REM FedUpDate Windows Command Wrapper
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fedupdate.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fedupdate.ps1" %*
)
