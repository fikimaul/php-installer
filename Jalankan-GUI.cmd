@echo off
rem Jalankan GUI PHP Updater (double-click saja, tanpa jendela console).
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0update-php-gui.ps1"
