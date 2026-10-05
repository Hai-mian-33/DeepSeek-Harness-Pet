@echo off
rem start-pet.cmd - launch the Blue Whale Pet (bridge + shell).
rem
rem The bridge polls the DSH session store and publishes state/pet-state.json;
rem the shell renders it. Both run detached and hidden, so this window can be closed
rem as soon as it prints "started".
rem
rem Run this from a NORMAL terminal (cmd or PowerShell), not from inside an
rem automation/sandbox host: raising the Harness window needs the right to control
rem another application's window, which a restricted host does not grant. Everything
rem else - the status feed, the bubble, dragging, edge fixing - works either way.
rem
rem This file is deliberately ASCII-only: cmd.exe mis-parses multibyte sequences in
rem comments as commands.

setlocal
pushd "%~dp0.." || exit /b 1

set "NODE=%LOCALAPPDATA%\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
if not "%~1"=="" set "NODE=%~1"
if not exist "%NODE%" (
  echo [pet] bundled node not found at "%NODE%" 1>&2
  echo [pet] usage: start-pet.cmd [path-to-node.exe] 1>&2
  popd
  exit /b 1
)

set "ROOT=%CD%"
echo [pet] root: %ROOT%
echo [pet] node: %NODE%

rem Stop anything already running first, so a second launch cannot leave two pets
rem (or two bridges writing the same state file) on screen.
echo [pet] stopping any previous instance...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\tools\Stop-Pet.ps1" >nul 2>&1

rem Clear any "stay closed" marker left by the pet's own Quit command. Starting the pet by
rem hand is an explicit request for it to be visible, so it must override an earlier quit;
rem otherwise a running watchdog would shut the pet down again seconds after this script
rem started it.
rem
rem This comment is in English on purpose. The file must stay ASCII-only because cmd.exe
rem mis-parses multibyte characters in a .cmd file, so the pet's Quit item is described
rem rather than named by its Chinese menu label.
if exist "%ROOT%\state\pet-quit" del /q "%ROOT%\state\pet-quit" >nul 2>&1

echo [pet] starting bridge...
start "dsh-pet-bridge" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath '%NODE%' -ArgumentList 'src\bridge.mjs' -WorkingDirectory '%ROOT%' -WindowStyle Hidden"

rem Give the bridge a moment to publish its first snapshot before the shell reads it.
timeout /t 2 /nobreak >nul

echo [pet] starting shell...
start "dsh-pet-shell" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%\src\shell\WhalePet.ps1"

echo [pet] started. Look near the bottom-right of your primary display.
echo [pet] to stop it later: powershell -File "%ROOT%\tools\Stop-Pet.ps1"
popd
endlocal
