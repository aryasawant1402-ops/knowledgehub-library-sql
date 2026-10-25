@echo off
title KnowledgeHub Public Library
cd /d "%~dp0"
if not exist node_modules (
  echo Installing packages, please wait...
  call npm install
)
start "" cmd /c "timeout /t 2 >nul & start http://localhost:3000"
node server.js
pause
