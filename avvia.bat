@echo off
REM Launcher per NetAdapter-Manager.ps1
REM Richiede PowerShell 7+ e privilegi di amministratore
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetAdapter-Manager.ps1"
) else (
    echo PowerShell 7 non trovato!
    echo Scaricalo da: https://aka.ms/powershell
    pause
    exit /b 1
)

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Errore durante l'esecuzione.
    pause
)
endlocal
