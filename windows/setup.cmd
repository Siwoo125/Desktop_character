@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
cd /d "%~dp0.."
if exist ".venv-windows\Scripts\python.exe" (
    set "PET_PY=.venv-windows\Scripts\python.exe"
    goto bootstrap
)
where py >nul 2>&1
if not errorlevel 1 (
    for %%V in (3.13 3.14 3.12 3.11) do (
        py -%%V -c "import sys; assert sys.maxsize > 2**32" >nul 2>&1
        if not errorlevel 1 (
            set "PET_PY=py -%%V"
            goto bootstrap
        )
    )
)
where python >nul 2>&1
if not errorlevel 1 (
    python -c "import sys; assert (3,11) <= sys.version_info[:2] < (3,15) and sys.maxsize > 2**32" >nul 2>&1
    if not errorlevel 1 (
        set "PET_PY=python"
        goto bootstrap
    )
)
echo Install 64-bit Python 3.13 from https://www.python.org/downloads/windows/
echo Then double-click Start-Windows.cmd again.
exit /b 2
:bootstrap
%PET_PY% "windows\bootstrap.py"
exit /b %ERRORLEVEL%
