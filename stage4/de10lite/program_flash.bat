@echo off
rem program_flash.bat - write output_files\lanex.pof into the MAX 10's internal flash and
rem verify it: from then on the board starts the desk lane by itself at every power-up.
rem Same as Quartus: Tools > Programmer > Add File lanex.pof > Program/Configure + Verify > Start.
setlocal
cd /d "%~dp0"
set "Q=%QUARTUS_ROOTDIR%"
if "%Q%"=="" set "Q=C:\altera_lite\25.1std\quartus"
"%Q%\bin64\quartus_pgm.exe" -c USB-Blaster -m JTAG -o "pv;output_files\lanex.pof"
if errorlevel 1 (echo. & echo PROGRAMMING FAILED - is the board plugged in, and the USB-Blaster driver installed? & pause & exit /b 1)
echo Done. Unplug and plug the board back in: the desk lane starts by itself.
pause
