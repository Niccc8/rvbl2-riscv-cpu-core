@echo off
rem compile.bat - build the LaneX desk lane (output_files\lanex.sof and lanex.pof).
rem Same as Quartus: Processing > Start Compilation. About 2 minutes.
setlocal
cd /d "%~dp0"
set "Q=%QUARTUS_ROOTDIR%"
if "%Q%"=="" set "Q=C:\altera_lite\25.1std\quartus"
"%Q%\bin64\quartus_sh.exe" --flow compile lanex
if errorlevel 1 (echo. & echo COMPILE FAILED - see the messages above. & pause & exit /b 1)
echo.
echo Compiled. Timing (every Slack must be positive; a negative one: see README, "Timing"):
findstr /C:"Type" /C:"Slack" output_files\lanex.sta.summary
pause
