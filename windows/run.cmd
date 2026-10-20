@echo off
setlocal
cd /d "%~dp0.."
call "windows\setup.cmd"
if errorlevel 1 exit /b 1
if not "%~1"=="" goto console
start "" ".venv-windows\Scripts\pythonw.exe" "windows\launch.py"
exit /b %ERRORLEVEL%
:console
".venv-windows\Scripts\python.exe" "windows\launch.py" %*
exit /b %ERRORLEVEL%
