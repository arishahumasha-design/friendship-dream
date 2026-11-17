@echo off
title Friendship Dream - local site
cd /d "%~dp0"

if not exist node_modules (
  echo First time setup: installing packages, please wait...
  call npm install
)

echo.
echo Starting Friendship Dream at http://localhost:3000
echo Keep this window open while you use the site. Close it to stop.
echo.

start "" cmd /c "timeout /t 8 /nobreak >nul & start http://localhost:3000"
call npm run dev
pause
