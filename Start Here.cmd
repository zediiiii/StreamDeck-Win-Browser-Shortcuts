@echo off
REM ===================================================================
REM  Double-click this file to open the Stream Deck tab button tool.
REM  Nothing needs to be installed and nothing is changed system-wide.
REM ===================================================================
cd /d "%~dp0"

REM Files downloaded from the internet are blocked by Windows until
REM released. This clears that mark for this folder only.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath '%~dp0' -Recurse -Include *.ps1,*.vbs,*.cmd -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

if not exist "%~dp0New-TabButton.ps1" (
  echo.
  echo   New-TabButton.ps1 is missing from this folder.
  echo   Keep all the files together and try again.
  echo.
  pause
  exit /b 1
)

REM powershell.exe, not pwsh.exe - the UI Automation assemblies are
REM .NET Framework only.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0New-TabButton.ps1"
