@echo off
rem Start the PC test app (scripts\viewer.py). Extra arguments are passed on,
rem e.g.  viewer.bat --port COM4 --device "C8 USB3.0 Video"
cd /d "%~dp0"

py -3 -c "import numpy, serial, PIL" 2>nul
if errorlevel 1 (
    echo Python 3 with numpy, pyserial and Pillow is needed:
    echo     py -3 -m pip install numpy pyserial pillow
    pause
    exit /b 1
)
where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo ffmpeg was not found on the PATH.
    pause
    exit /b 1
)

py -3 scripts\viewer.py %*
if errorlevel 1 pause
