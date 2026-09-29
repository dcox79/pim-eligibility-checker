@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    powershell.exe -NoLogo -NoProfile -File "%~dp0scripts\Start-PimEligibility.ps1"
) else (
    pwsh.exe -NoLogo -NoProfile -File "%~dp0scripts\Start-PimEligibility.ps1"
)
set "result=%errorlevel%"
echo.
pause
exit /b %result%
