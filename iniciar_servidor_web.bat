@echo off
title Panel Web de Monitoreo Termico
cd /d "%~dp0"
echo ====================================================================
echo  INICIANDO PANEL WEB DE MONITOREO TERMICO (PUERTO 8080)...
echo ====================================================================
echo  Abre en tu navegador: http://localhost:8080
echo  (O desde tu telefono/otra laptop en la misma red o VPN)
echo ====================================================================
echo.
python monitor.py --web --port 8080
pause
