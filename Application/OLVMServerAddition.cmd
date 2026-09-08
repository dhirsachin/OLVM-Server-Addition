@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "OLVM_HIDDEN_LAUNCH=0"
if /I "%~1"=="--hidden" set "OLVM_HIDDEN_LAUNCH=1"
set "OLVM_SERVER_ADDITION_CMD_CLOCK=%TIME%"
if not defined OLVM_SERVER_ADDITION_STARTUP_PROTOCOL set "OLVM_SERVER_ADDITION_STARTUP_PROTOCOL=1"
if not defined OLVM_SERVER_ADDITION_STARTUP_ENTRY set "OLVM_SERVER_ADDITION_STARTUP_ENTRY=CMD"
set "OLVM_SERVER_ADDITION_LAUNCH_ROOT=%~dp0"
if not defined OLVM_SERVER_ADDITION_PACKAGE_LOCATION set "OLVM_SERVER_ADDITION_PACKAGE_LOCATION=Local"
if "%OLVM_SERVER_ADDITION_LAUNCH_ROOT:~0,2%"=="\\" set "OLVM_SERVER_ADDITION_PACKAGE_LOCATION=UNC"
set "OLVM_SERVER_ADDITION_LAUNCH_ROOT="
title OLVM Server Addition Launcher

rem Start the package from either a local folder or a UNC share without
rem attempting to change the server's effective PowerShell execution policy.
pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo OLVM Server Addition could not access its package directory.
    echo Confirm that the network location is available and that you have read access.
    if "%OLVM_HIDDEN_LAUNCH%"=="0" pause
    exit /b 1
)

set "OLVM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "OLVM_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "OLVM_SCRIPT=%CD%\OLVMServerAddition.ps1"

if not exist "%OLVM_POWERSHELL%" (
    echo Windows PowerShell 5.1 was not found at the expected operating-system path.
    popd
    if "%OLVM_HIDDEN_LAUNCH%"=="0" pause
    exit /b 1
)

if not exist "%OLVM_SCRIPT%" (
    echo OLVMServerAddition.ps1 was not found beside this launcher.
    popd
    if "%OLVM_HIDDEN_LAUNCH%"=="0" pause
    exit /b 1
)

"%OLVM_POWERSHELL%" -NoLogo -NoProfile -STA -File "%OLVM_SCRIPT%"
set "OLVM_EXIT_CODE=%ERRORLEVEL%"

popd

if not "%OLVM_EXIT_CODE%"=="0" (
    echo.
    echo OLVM Server Addition stopped with exit code %OLVM_EXIT_CODE%.
    echo Review the message above before closing this window.
    if "%OLVM_HIDDEN_LAUNCH%"=="0" pause
)

endlocal & exit /b %OLVM_EXIT_CODE%
