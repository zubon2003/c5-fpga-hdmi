# Tang Primer 25K core base board

A 100 x 50 mm four-layer board that replaces the Tang Primer 25K Dock for
this project: the 25K core module, one SDRAM, USB-C JTAG/UART, one HDMI
output, both XIAO ESP32-C5 receivers on sockets, and six buttons.

Not built or tested yet.

## Files

| File | |
|---|---|
| `gen_base.py` | places the parts and sets the nets (KiCad 8 Python); edit this, not the PCB |
| `route.py` | runs `gen_base.py`, draws the HDMI traces, routes the rest with Freerouting 1.7, fills the planes |
| `tang25k_base.kicad_pcb`, `.kicad_pro` | the board (KiCad 8) |
| `export_jlc.py` | writes `jlcpcb/`: Gerber zip, BOM and CPL for JLCPCB assembly (LCSC numbers in the script; XIAO sockets left for hand soldering) |

Rebuild: `"C:/Program Files/KiCad/8.0/bin/python.exe" route.py 40`
(Freerouting from `%LOCALAPPDATA%\freerouting`; about 10 minutes. More
passes than about 40 sometimes never finish.)

## Layers

F.Cu and B.Cu signals, In1.Cu GND plane, In2.Cu +3V3 plane, GND pours on
both outer layers. Tracks 0.15 mm / clearance 0.127 mm, +5V and the XIAO
and HDMI 5 V nets 0.4 mm; vias 0.5 / 0.25 mm. Copper stays 0.45 mm off the
edge. All parts are on the top side.

## Core module

Two Hirose DF40C-60DS-0.4V(51) receptacles, 14.0 mm apart, placed as on
the Dock (pad geometry from Sipeed's `Tang_Primer_25K_Dock_60033_ibom.html`,
pin functions from the Dock and core schematics). The connectors need
reflow (JLCPCB assembly). The area under the module (silk corner marks)
has no parts.

The module makes its own 3.3 V (J2 46/48/50); the board feeds +5 V into
J2 52..60 and the bank supplies VCCIO0/1, VCCIO2/3, VCCIO6/7 from 3.3 V
through ferrite beads, as the Dock does. The 50 MHz oscillator (E2) and
the configuration flash are on the module.

## Parts

| Ref | Part |
|---|---|
| J1, J2 | Hirose DF40C-60DS-0.4V(51) |
| U1 | FTDI FT2232HL (LQFP-64), Y1 12 MHz (3225), U2 93LC56B EEPROM (optional) |
| U3 | Winbond W9825G6KH-6I, 32 MB SDRAM (TSOP-II 54) |
| U4 | 74HC165 (SOIC-16) |
| U6 | USBLC6-2SC6 (USB ESD) |
| J3 | USB-C, HRO TYPE-C-31-M-12 |
| J4 | HDMI type A, Amphenol 10029449-x01xLF footprint |
| J5..J8 | 1x7 female sockets for the two XIAOs |
| SW1..SW7 | XKB TS-1187A (5.1 x 5.1 mm) |
| D1, D2, D3 | ROHM RB160M-30: 5 V to each XIAO and to HDMI pin 18 |
| F1 | 1.5 A PTC (1206) |

## USB-C

FT2232HL, bus powered from the board's 3.3 V. Channel A is JTAG (MPSSE:
ADBUS0 TCK, 1 TDI, 2 TDO, 3 TMS) for openFPGALoader (`-c ft2232`) or the
Gowin programmer; channel B is a UART to the FPGA. Without the EEPROM
the chip enumerates as the stock 0403:6010.

## FPGA pins

Unchanged from `top.cst`: clock E2, SDRAM (except CS# and DQM), receiver 1
`iq[0..7]`, HDMI pairs, `link_tx` L5, `link_rx` K5, UART B3 (RX) / C3 (TX).

| Signal | Pin | Note |
|---|---|---|
| SDRAM CS#, LDQM, UDQM | - | tied to GND on the board (`sdram_fb.v` already drives DQM low) |
| SDRAM CKE | - | tied to 3.3 V |
| receiver 2 `iq2[0..7]` (Q0 Q1 Q2 QS I0 I1 I2 IS) | E11 E10 A11 A10 K11 L11 L6 K6 | |
| receiver 2 TX (`link_rx2`) | K9 | |
| 74HC165 SH/LD#, CLK, QH | H11, H10, L8 | buttons, active low, A..F = SW1..SW6 |
| user LED | L7 | high = on |
| JTAG | C1 TCK, B1 TMS, A2 TDO, A3 TDI | dedicated pins |
| DONE | D7 | LED |
| RECONFIG_N | D8 | SW7 |

The HDMI pairs keep the pins of `top.cst`, but on the board every pair's
P and N are swapped (H8, G7, F5, H5 go to the connector's minus pins) so
the traces run straight without crossing. The HDL has to invert the
serialised TMDS bits of all four channels.

Receiver wiring per XIAO: D0..D3 = Q0, Q1, Q2, Q sign; D10 = I0; D4 = TX
to the FPGA; D5 = RX from `link_tx` (both receivers); MTDO, MTDI, MTCK
(I1, I2, I sign) through wire holes under the XIAO, soldered on the back,
as on the PMOD carrier.

## Buttons

The 74HC165 loads A..F (SW1..SW6, pulled up, pressed = 0) on SH/LD# low,
then shifts on CLK; QH shows H first (tied high), then G (high), F..A.
Silk names: UP, DOWN, LEFT, RIGHT, OK, BACK.
