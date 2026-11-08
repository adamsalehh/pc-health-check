@echo off
chcp 65001 >nul
title PC Health Check (admin)
echo Requesting administrator rights (needed for SMART details and full cleanup)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','\"%~dp0PC-HealthCheck.ps1\"'"
