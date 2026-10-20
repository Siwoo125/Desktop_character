@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
cd /d "%~dp0.."
call "windows\setup.cmd"
if errorlevel 1 goto failed
".venv-windows\Scripts\python.exe" "windows\launch.py" --self-test --validate-assets --widget-check
if errorlevel 1 goto failed
".venv-windows\Scripts\python.exe" "windows\launch.py" --diagnose
if errorlevel 1 goto failed
echo.
echo Tests passed. Launch Start-Windows.cmd to check actual desktop behavior.
pause
exit /b 0
:failed
echo.
echo Test failed. Copy this output and the DesktopFriends log for troubleshooting.
pause
exit /b 1
