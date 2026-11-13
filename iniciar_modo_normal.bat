@echo off
title Monitor de Temperatura (Modo Normal)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1"
pause
