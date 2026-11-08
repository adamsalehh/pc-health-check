@echo off
chcp 65001 >nul
title PC Health Check
echo =====================================================
echo   PC Health Check - system overview and diagnostics
echo =====================================================
echo.
echo  Starting the check... it normally takes 1-3 minutes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PC-HealthCheck.ps1"
echo.
echo  Press any key to close this window.
pause >nul
