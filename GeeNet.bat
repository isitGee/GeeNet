@echo off
rem ============================================================================
rem  GeeNet - Windows Network Toolkit
rem  Diagnose | Troubleshoot | Repair
rem  Made by George Mwanga  +255762358050   github.com/isitgee
rem ----------------------------------------------------------------------------
rem  This launcher only starts GeeNet.ps1 with the best PowerShell it can find.
rem  Nothing is installed and nothing is downloaded. Diagnostics need no admin
rem  rights; repairs that change system settings ask for approval one at a time.
rem
rem  Usage:
rem     GeeNet.bat                     open the main menu (Beginner or Professional)
rem     GeeNet.bat -Beginner           go straight to guided troubleshooting
rem     GeeNet.bat -Professional       go straight to the classic tools
rem     GeeNet.bat -NoElevate          never offer to restart as Administrator
rem     GeeNet.bat -Ascii              use plain ASCII markers
rem     GeeNet.bat -SelfTest           run the internal self test and exit
rem     GeeNet.bat -Version            print the version and exit
rem     GeeNet.bat -Admin              restart GeeNet with Administrator rights
rem     GeeNet.bat /?                  short help
rem ============================================================================

setlocal EnableExtensions
title GeeNet - Windows Network Toolkit
set "GEENET_DIR=%~dp0"
set "GEENET_PS1=%GEENET_DIR%GeeNet.ps1"
set "GEENET_PWSH="
set "GEENET_ELEVATE="
set "GEENET_HELP="
set "GEENET_PAUSE="
set "GEENET_ARGS=%*"

rem ---- was this window opened by a double click? only then do we pause at the end
echo(%CMDCMDLINE% | find /i "%~nx0" >nul 2>&1
if not errorlevel 1 set "GEENET_PAUSE=1"

for %%A in (%*) do (
    if /i "%%~A"=="/?" set "GEENET_HELP=1"
    if /i "%%~A"=="-?" set "GEENET_HELP=1"
    if /i "%%~A"=="/help" set "GEENET_HELP=1"
    if /i "%%~A"=="-help" set "GEENET_HELP=1"
    if /i "%%~A"=="/admin" set "GEENET_ELEVATE=1"
    if /i "%%~A"=="-admin" set "GEENET_ELEVATE=1"
)

if defined GEENET_HELP (
    call :ShowHelp
    goto :Done
)

if not exist "%GEENET_PS1%" (
    echo.
    echo   GeeNet.ps1 was not found next to this launcher.
    echo   Expected it here: "%GEENET_PS1%"
    echo.
    echo   Keep GeeNet.bat and GeeNet.ps1 in the same folder and try again.
    echo.
    set "GEENET_PAUSE=1"
    goto :Done
)

rem ---- pick the best PowerShell available: 7+ if installed, otherwise Windows PowerShell 5.1
where /q pwsh.exe
if "%ERRORLEVEL%"=="0" set "GEENET_PWSH=pwsh.exe"
if not defined GEENET_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "GEENET_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined GEENET_PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "GEENET_PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined GEENET_PWSH if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "GEENET_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined GEENET_PWSH set "GEENET_PWSH=powershell.exe"

if defined GEENET_ELEVATE goto :Elevate

rem ---- normal start
"%GEENET_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%GEENET_PS1%" %GEENET_ARGS%
set "GEENET_CODE=%ERRORLEVEL%"
if not "%GEENET_CODE%"=="0" (
    echo.
    if "%GEENET_CODE%"=="1" (
        echo   GeeNet's self test reported a problem. The report above says which check failed.
    ) else (
        echo   GeeNet closed with code %GEENET_CODE%.
    )
    set "GEENET_PAUSE=1"
)
goto :Done

rem ============================================================================
rem  Optional: restart GeeNet with Administrator rights (only when asked for).
rem  Kept out of the main path so the error level is read after PowerShell exits.
rem ============================================================================
:Elevate
set "GEENET_CLEAN=%GEENET_ARGS%"
call set "GEENET_CLEAN=%%GEENET_CLEAN:/admin=%%"
call set "GEENET_CLEAN=%%GEENET_CLEAN:-admin=%%"
echo.
echo   Asking Windows to restart GeeNet with Administrator rights.
echo   If a "User Account Control" box appears, choose Yes.
echo.
"%GEENET_PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "$a = @('-NoProfile','-ExecutionPolicy','Bypass','-File','%GEENET_PS1%'); if ([string]::IsNullOrWhiteSpace('%GEENET_CLEAN%') -eq $false) { $a += '%GEENET_CLEAN%' }; Start-Process -FilePath '%GEENET_PWSH%' -Verb RunAs -ArgumentList $a" 2>nul
set "GEENET_CODE=%ERRORLEVEL%"
if not "%GEENET_CODE%"=="0" (
    echo   The elevation request was cancelled or refused by Windows.
    echo   GeeNet still works without Administrator rights - only the repairs
    echo   that change system settings need them.
    echo.
    set "GEENET_PAUSE=1"
) else (
    echo   The Administrator window is opening. This one can be closed.
    echo.
)
goto :Done

:Done
if defined GEENET_PAUSE (
    echo.
    echo   Press any key to close this window ...
    pause >nul
)
endlocal
exit /b 0

rem ============================================================================
:ShowHelp
echo.
echo   GeeNet - Windows Network Toolkit   (Diagnose ^| Troubleshoot ^| Repair)
echo   Made by George Mwanga  +255762358050   github.com/isitgee
echo.
echo   Double click this file for the menu, or use one of these:
echo.
echo     GeeNet.bat -Beginner       guided troubleshooting (no technical questions asked)
echo     GeeNet.bat -Professional   the classic diagnostic tools
echo     GeeNet.bat -NoElevate      never offer to restart as Administrator
echo     GeeNet.bat -Ascii          plain ASCII markers instead of symbols
echo     GeeNet.bat -SelfTest       check GeeNet itself and write a report
echo     GeeNet.bat -Version        print the version
echo     GeeNet.bat -Admin          restart with Administrator rights
echo     GeeNet.bat /?              this help
echo.
echo   Reports are written to the "reports" folder next to GeeNet.ps1, and the
echo   path is always printed on screen as well.
echo.
exit /b 0
