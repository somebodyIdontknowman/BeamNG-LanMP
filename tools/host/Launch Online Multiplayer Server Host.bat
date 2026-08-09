@echo off
setlocal enabledelayedexpansion

:: LANMP host script. Double click this to host a game.
:: Edit the four settings below if you want.

set NAME=%USERNAME%'s LANMP Server
set PORT=4144
set MAXPLAYERS=8
set MAP=/levels/gridmap_v2/info.json

title LANMP Server - %NAME%

if not exist "%~dp0lanmp_server.exe" (
  echo lanmp_server.exe is missing - keep this script next to it.
  pause
  exit /b 1
)

:: Best effort firewall rule so other players can reach us. Needs admin; if it
:: fails the server still runs, you just have to allow it when Windows asks.
netsh advfirewall firewall show rule name="LANMP Server" >nul 2>&1
if errorlevel 1 (
  netsh advfirewall firewall add rule name="LANMP Server" dir=in action=allow ^
    protocol=UDP localport=%PORT% >nul 2>&1
  if errorlevel 1 (
    echo [!] Could not add the firewall rule automatically.
    echo     Right click this file and "Run as administrator" once, or allow
    echo     lanmp_server.exe when Windows asks.
    echo.
  )
)

echo ============================================================
echo  LANMP Server
echo ============================================================
echo  Name : %NAME%
echo  Port : UDP %PORT%   Map: %MAP%
echo.
echo  Players on your network just press Refresh in the LANMP app.
echo  If they need to type it in, your addresses are:
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /c:"IPv4 Address"') do (
  set IP=%%A
  echo    !IP: =!:%PORT%
)
echo.
echo  Playing over the internet? Forward UDP %PORT% to this PC.
echo  Close this window to stop the server.
echo ============================================================
echo.

"%~dp0lanmp_server.exe" --name "%NAME%" --port %PORT% --max-players %MAXPLAYERS% --map "%MAP%"

echo.
echo Server stopped.
pause
