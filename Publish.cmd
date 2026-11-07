@echo off
rem Opens the photo-frame publisher window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0tools\publish-gui.ps1"
