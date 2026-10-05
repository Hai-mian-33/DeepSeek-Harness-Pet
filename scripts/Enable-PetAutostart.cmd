@echo off
rem ============================================================================
rem Enable-PetAutostart.cmd - one command: install autostart AND start recording
rem evidence, so the feature can be verified by closing and reopening Harness.
rem
rem WHY THIS EXISTS
rem   An AI session runs INSIDE DeepSeek Harness, so it cannot close Harness to
rem   test "pet hides when Harness closes" - doing so would kill the session doing
rem   the checking. This script hands that job to you with everything set up:
rem   the autostart entry is written, the watchdog is started, and a detached
rem   recorder begins logging the pet's visibility every 2 seconds.
rem
rem WHAT YOU DO
rem   1. Run this file (double-click, or from a terminal).
rem   2. Close DeepSeek Harness completely. Wait ~40 seconds.
rem   3. Reopen DeepSeek Harness. Wait ~30 seconds.
rem   4. The recorder stops by itself and writes the verdict to:
rem        build\autostart-evidence.txt
rem
rem The recorder keeps running for up to 15 minutes, so there is no rush.
rem
rem This file must stay ASCII-only with CRLF line endings: cmd.exe mis-parses
rem multibyte characters, and a .cmd with bare LF endings is fragmented into
rem garbage errors. Both mistakes have broken this project's scripts before.
rem ============================================================================

setlocal
pushd "%~dp0.." || exit /b 1

echo.
echo === Blue Whale Pet : enable autostart + start evidence recording ===
echo.

if not exist "tools\Install-Autostart.ps1" (
  echo [ERROR] tools\Install-Autostart.ps1 not found. Run this from the project folder.
  popd
  exit /b 1
)

echo [1/2] Installing the Startup entry and starting the watchdog...
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\Install-Autostart.ps1"
if errorlevel 2 (
  echo.
  echo [ERROR] Could not install. Read the message above.
  popd
  exit /b 1
)

echo.
echo [2/2] Starting the evidence recorder in the background...
start "dsh-pet-evidence" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "tools\Watch-AutostartEvidence.ps1"

echo.
echo ==================================================================
echo  Now do this, in order:
echo.
echo    1. Close DeepSeek Harness completely. Wait about 40 seconds.
echo    2. Reopen DeepSeek Harness. Wait about 30 seconds.
echo.
echo  Expected: the pet disappears shortly after Harness closes, and
echo            comes back on its own when Harness reopens.
echo.
echo  The result is written to:
echo    %CD%\build\autostart-evidence.txt
echo.
echo  Read it any time; the recorder gives up after 15 minutes.
echo ==================================================================
echo.

popd
endlocal
