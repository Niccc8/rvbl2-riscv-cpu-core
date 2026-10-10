@echo off
rem program_sram.bat - load output_files\lanex.sof into the FPGA (runs at once; lost at power-off).
rem Same as Quartus: Tools > Programmer > Add File lanex.sof > Start.
setlocal
cd /d "%~dp0"
set "Q=%QUARTUS_ROOTDIR%"
if "%Q%"=="" set "Q=C:\altera_lite\25.1std\quartus"
"%Q%\bin64\quartus_pgm.exe" -c USB-Blaster -m JTAG -o "p;output_files\lanex.sof"
if errorlevel 1 (echo. & echo PROGRAMMING FAILED - is the board plugged in, and the USB-Blaster driver installed? & pause & exit /b 1)
echo Done: the board runs the desk lane.
pause
