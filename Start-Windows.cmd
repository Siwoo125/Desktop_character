@echo off
setlocal
pushd "%~dp0"
call "windows\run.cmd" %*
set "PET_EXIT=%ERRORLEVEL%"
popd
if not "%PET_EXIT%"=="0" pause
exit /b %PET_EXIT%
