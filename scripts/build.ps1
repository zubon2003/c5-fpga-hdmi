# Batch build with Gowin EDA Education; output: impl/pnr/c5_fpga_hdmi.fs
$gw = "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe"
Set-Location (Split-Path $PSScriptRoot)
& $gw scripts/build.tcl
