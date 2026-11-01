# XIAO ESP32-C5 PMOD carrier

A 20 x 36 mm two-layer board that plugs a XIAO ESP32-C5 (C5VRX-5) into a
Tang Primer 25K Dock PMOD port (J4 or J6; J5 holds the PMOD DVI). All eight IQ lines go through
the PMOD plug; UART, 5 V and ground are wire pads on the bottom edge. The
same board is used for both receivers of the diversity setup.

v3: the XIAO is turned 90 degrees clockwise (top view): antenna end
towards the PMOD plug, USB-C pointing away from the Dock. The XIAO
(17.8 mm wide) now sits inside the 20 mm board width. The board is 20 mm
wide (v1 was 33 mm) so that it clears the parts next to the PMOD port.
All right-angle track corners are cut to two 45 degree bends. The PMOD
pin order changed again with the rotation (see Signals).

Not built or tested yet.

## Files

| File | |
|---|---|
| `gen_board.py` | generates the board (KiCad 8 Python); edit this, not the PCB |
| `c5_pmod_carrier.kicad_pcb` | the board (KiCad 8) |
| `c5_pmod_carrier_gerber.zip`, `gerber/` | Gerber + Excellon for the board house |
| `panelize.py` | makes the V-cut panel from the single board (run after `gen_board.py`) |
| `c5_pmod_carrier_panel.kicad_pcb`, `c5_pmod_carrier_panel_gerber.zip`, `gerber_panel/` | the panel and its Gerbers (only the zip is in git; `panelize.py` makes the rest) |
| `LOGO_*.kicad_mod` | logos; `gen_board.py` scales them and puts them on the back silkscreen (ZUBON TECH. 18 mm wide along the bottom edge, Tinywhoop 11.5 mm between the socket columns) |

Regenerate: `"C:/Program Files/KiCad/8.0/bin/python.exe" gen_board.py`,
then re-export the Gerbers with `kicad-cli pcb export gerbers` / `drill`.
DRC (2026-10-31, v3): 0 errors, 0 unconnected; 8 warnings that the custom
footprints are not in a library.

## Parts

| Ref | Part |
|---|---|
| J1 | 2x6 pin header, 2.54 mm, **right angle**, male, on the top side |
| J2, J3 | 1x7 female socket, 2.54 mm, vertical (the XIAO plugs in with its own male headers) |
| D1 | Schottky diode, SOD-123: ROHM RB160M-30 (30 V 1 A, Vf 0.43 V; Akizuki 101398). Any 1 A Schottky in SOD-123 fits |

## Orientation

Dock PMOD numbering (Dock schematic): 1/2 = +3V3, 3/4 = GND, 5..12
signals. Looking into the Dock socket from outside with the Dock
component side up, pins 1/2 are on the left and the odd pins are in the
upper row (checked on J4 against the existing wiring). The carrier then
plugs in level with the Dock, component side up ("THIS SIDE UP"), with
the square pad (pin 1) on the left. Plugged in upside down, the XIAO
outputs would drive the Dock's +3V3 and GND pins.

PMOD pins 1/2 (+3V3) are not connected; the XIAO runs from the 5 V pad.

## Signals

The PMOD order is chosen so that all traces are on the top layer
without crossings (the bottom layer is a solid ground plane), so it is
not the order of the earlier jumper wiring (nor of v1/v2). `top.cst` has
to follow it:

| PMOD | Signal | XIAO | J4 pin (FPGA) | J6 pin (FPGA) |
|---|---|---|---|---|
| 5 | I bit 1 | MTDO (GPIO5), wire | C11 | H5 |
| 6 | I bit 0 | D10 (GPIO10) | C10 | J5 |
| 7 | I bit 2 | MTDI (GPIO3), wire | B11 | H8 |
| 8 | I sign | MTCK (GPIO4), wire | B10 | H7 |
| 9 | Q bit 1 | D1 (GPIO0) | D11 | G7 |
| 10 | Q bit 0 | D0 (GPIO1) | D10 | G8 |
| 11 | Q sign | D3 (GPIO7) | G11 | F5 |
| 12 | Q bit 2 | D2 (GPIO25) | G10 | G5 |

So for the receiver on J4: `iq[0]` D10, `iq[1]` D11, `iq[2]` G10,
`iq[3]` G11, `iq[4]` C10, `iq[5]` C11, `iq[6]` B11, `iq[7]` B10; on J6:
G8, G7, G5, F5, J5, H5, H8, H7.

The PMOD DVI moved to the middle port J5 on 2026-11-01, so the second
receiver goes on J6. The receiver UART is on the Dock USB-A port (FPGA
L6 = D+ to the C5's RX, K6 = D- from its TX; `top.cst`), not on a PMOD.

## Wires

Bottom edge, right to left (2.54 mm apart): RX, TX, GND, 5V. D1 sits at
the bottom left, below the XIAO's 5V pin.

| Pad | To |
|---|---|
| RX (D5) | FPGA TX (both receivers on one wire) |
| TX (D4) | FPGA RX (receiver 1 only) |
| GND | Dock GND |
| 5V | Dock +5 V: USB-A VBUS (pin 1), or J7 pin 4 |
| MTDO, MTDI, MTCK holes | the XIAO's bottom-side pads of the same name; the wire goes down through the hole and is soldered on the back |

D1 keeps the XIAO's own USB VBUS out of the Dock's 5 V, so the XIAO's
USB-C can stay plugged into a PC (the XIAO 5V pin is its VBUS).

XIAO geometry (pins, 15.24 mm rows, bottom pads) is taken from Seeed's
"Seeed Studio XIAO ESP32C5 V1.1" KiCad project (2025-12-25).

## Panel

`panelize.py` puts 4 x 2 boards side by side with no gap and adds a 5 mm
rail (no copper) on the top and bottom edge: 80 x 82 mm, 8 boards. All
inner lines are V-cuts, straight across the panel, including the line
between each rail and the boards. They are in Edge.Cuts together with the
panel outline, and again in Cmts.User (`User_Comments.gbr` in the zip)
with "V-CUT" labels. Copper stays 0.5 mm from every board edge.

When ordering, choose the board house's "panel by customer" option with
V-cut, give the panel size (80 x 82 mm) and note that the inner outline
lines are the V-cuts. The panel DRC reports the copies as unconnected
because they share net names; DRC is checked on the single board.
