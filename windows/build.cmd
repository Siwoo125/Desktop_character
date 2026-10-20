@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
cd /d "%~dp0.."
call "windows\setup.cmd"
if errorlevel 1 goto failed
".venv-windows\Scripts\python.exe" -m pip install "pyinstaller==6.22.3"
if errorlevel 1 goto failed
".venv-windows\Scripts\python.exe" "windows\build.py"
if errorlevel 1 goto failed
echo.
echo EXE: dist\windows\DesktopCharacter\DesktopCharacter.exe
echo Share the entire DesktopCharacter folder or the generated ZIP, not only the EXE.
pause
exit /b 0
:failed
echo Build failed. See the output above.
pause
exit /b 1
