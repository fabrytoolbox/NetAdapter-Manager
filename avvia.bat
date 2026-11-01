@echo off
REM ============================================================
REM  NetAdapter Manager - Launcher
REM  Versione: 1.2 (Matrix Edition)
REM  Delega l'auto-elevazione a NetAdapter-Manager.ps1
REM ============================================================
title NetAdapter Manager - Matrix Edition
setlocal
cd /d "%~dp0"

REM --- 1. Controllo PowerShell 7 ---
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [ERRORE] PowerShell 7 non trovato!
    echo  Scaricalo da: https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

REM --- 2. Avvio diretto (lo .ps1 si auto-eleva se serve) ---
echo.
echo  ============================================================
echo   NETADAPTER MANAGER v1.2 - MATRIX EDITION
echo  ============================================================
echo   Avvio in corso...
echo.
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetAdapter-Manager.ps1"

REM --- 3. Gestione eventuale errore ---
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [ERRORE] Esecuzione terminata con codice %ERRORLEVEL%.
    pause
)
endlocal