@echo off
title Monitor de Temperatura y Salud del Sistema
cd /d "%~dp0"

echo ====================================================================
echo  INICIANDO MONITOR DE TEMPERATURA (MODO ADMINISTRADOR)...
echo  Si aparece la ventana de Windows, haz clic en "Si".
echo ====================================================================

set "MONITOR_SCRIPT=%~dp0monitor.ps1"
powershell -NoProfile -Command "Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File ' + [char]34 + $env:MONITOR_SCRIPT + [char]34) -Verb RunAs"
if %errorlevel% neq 0 (
    echo.
    echo [AVISO] No se pudo iniciar como Administrador. Iniciando en modo normal...
    powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0monitor.ps1"
)
