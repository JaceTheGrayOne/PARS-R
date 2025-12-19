@echo off
setlocal
title Test Report Converter

:: Locate the PowerShell script next to this script so paths stay relative
set "ScriptDir=%~dp0"
set "PsScript=%ScriptDir%TREX.ps1"

:: Fail if PowerShell script is missing
if not exist "%PsScript%" (
    color 0C
    echo Can't find TREX.ps1 in "%ScriptDir%". Keep the .bat and .ps1 together.
    pause
    exit /b 1
)

:Prompt
cls
:: Input XML file user prompt
echo XML TEST REPORT CONVERTER
echo -------------------------
echo Drop or type the XML file path, then press Enter.
set /p "InputXml=Path: "

:: Clean dragged file path data
set "InputXml=%InputXml:"=%"
if not exist "%InputXml%" (
    echo.
    echo File not found: "%InputXml%"
    timeout /t 2 >nul
    goto Prompt
)

:: Derive output path from input, same base name, .html extension
for %%F in ("%InputXml%") do (
    set "WorkDir=%%~dpF"
    set "FileName=%%~nF"
)
set "OutputHtml=%WorkDir%%FileName%.html"

echo.
echo Converting...
echo Input : "%InputXml%"
echo Output: "%OutputHtml%"
echo.

:: Call PowerShell, bypass execution policy
set "PwshExe=C:\Users\1130538\Downloads\New folder\PowerShell-7.5.2-win-x64\pwsh.exe"
if not exist "%PwshExe%" set "PwshExe=pwsh.exe"

"%PwshExe%" -NoProfile -ExecutionPolicy Bypass -File "%PsScript%" -XmlPath "%InputXml%" -OutputHtmlPath "%OutputHtml%"

:: On success: open the result in Edge otherwise signal failure
if %ERRORLEVEL% EQU 0 (
    echo Done. Opening in Edge...
    start msedge "%OutputHtml%"
) else (
    color 0C
    echo Conversion failed.
)

:: Persist window
echo.
pause
