"""Generate the Tang Primer 25K core base board (replaces the Dock).

Run with KiCad 8's Python:
  "C:/Program Files/KiCad/8.0/bin/python.exe" gen_base.py

Then route.py routes it with Freerouting and fills the planes.

Board coordinates are mm, origin at the top-left corner, y down, top view.
Four layers: F.Cu / B.Cu signals, In1.Cu GND plane, In2.Cu +3V3 plane.

What is on it:
  - the Tang Primer 25K core module on two Hirose DF40C-60DS-0.4V(51)
    receptacles, placed exactly as on the Dock (pad geometry from Sipeed's
    Tang_Primer_25K_Dock_60033 ibom; pin functions from the Dock and core
    schematics)
  - USB-C -> FT2232HL: channel A = JTAG (MPSSE), channel B = UART to the FPGA
  - one 16-bit SDRAM (W9825G6KH, TSOP-II 54); CS# and DQM tied low
  - HDMI type A, driven straight from bank 1 (pins as top.cst); the P/N of
    every pair are swapped on the board so the traces do not cross, so the
    HDL inverts the TMDS bits
  - two XIAO ESP32-C5 receivers on sockets, all IQ lines to the FPGA
  - six buttons read through a 74HC165, plus a RECONFIG button
  - LEDs: power, DONE, one user LED

The core module supplies 3.3 V (J2 46/48/50, its own regulator, as on the
Dock); the board feeds +5 V (J2 52..60) and the bank supplies VCCIO0/1,
2/3, 6/7 from 3.3 V through ferrite beads.
"""
import json
import os

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
FPLIB = "C:/Program Files/KiCad/8.0/share/kicad/footprints"
OUT = os.path.join(HERE, "tang25k_base.kicad_pcb")

W, H = 100.0, 50.0

mm = pcbnew.FromMM


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


board = pcbnew.BOARD()
ds = board.GetDesignSettings()
ds.SetCopperLayerCount(4)
board.SetLayerName(pcbnew.In1_Cu, "In1.Cu")
board.SetLayerName(pcbnew.In2_Cu, "In2.Cu")
board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
ds.m_TrackMinWidth = mm(0.127)
ds.m_MinClearance = mm(0.127)
ds.m_ViasMinSize = mm(0.5)
ds.m_MinThroughDrill = mm(0.25)
ds.m_HoleToHoleMin = mm(0.25)
ds.m_CopperEdgeClearance = mm(0.3)
ns = ds.m_NetSettings
nc = ns.m_DefaultNetClass
nc.SetClearance(mm(0.127))
nc.SetTrackWidth(mm(0.15))
nc.SetViaDiameter(mm(0.5))
nc.SetViaDrill(mm(0.25))

nets = {}


def net(name):
    if name not in nets:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    return nets[name]


# ---------------------------------------------------------------------------
# core module connectors (pin -> FPGA ball, from the schematics)
# ---------------------------------------------------------------------------
J1_BALL = {3: "L9", 5: "K9", 7: "J8", 9: "K8", 11: "F7", 13: "F6", 17: "E8",
           19: "B3", 21: "C3", 23: "E3", 25: "D7", 33: "J11", 35: "J10",
           37: "H11", 39: "H10", 41: "G11", 43: "G10", 47: "D11", 49: "D10",
           51: "C11", 53: "C10", 55: "B11", 57: "B10",
           4: "H5", 6: "J5", 8: "L5", 10: "K5", 12: "H8", 14: "H7", 16: "G7",
           18: "G8", 20: "F5", 22: "G5", 30: "L6", 32: "K6", 34: "K7", 36: "J7",
           38: "L7", 40: "L8", 42: "L10", 44: "K10", 46: "K11", 48: "L11",
           52: "E11", 54: "E10", 56: "A11", 58: "A10"}
J1_PWR = {**{n: "GND" for n in (1, 2, 15, 27, 28, 45, 50, 59, 60)},
          24: "VCCIO01", 26: "VCCIO01", 29: "VCCIO67", 31: "VCCIO67"}
J2_BALL = {3: "B2", 5: "C2", 7: "F2", 9: "F1", 11: "A1", 13: "D8", 15: "E1",
           17: "D1", 21: "C1", 23: "B1", 25: "A2", 27: "A3",
           6: "L2", 8: "L1", 10: "K1", 12: "K2", 14: "J4", 16: "K4", 18: "G2",
           20: "G1", 22: "L4", 24: "L3", 26: "J1", 28: "J2", 30: "G4",
           32: "H4", 34: "H1", 36: "H2"}
J2_PWR = {**{n: "GND" for n in (1, 19, 29, 35, 41, 47, 53, 59)},
          2: "VCCIO23", 4: "VCCIO23", 46: "+3V3", 48: "+3V3", 50: "+3V3",
          **{n: "+5V" for n in (52, 54, 56, 58, 60)}}

# FPGA ball -> net. SDRAM as top.cst (CS# and DQM tied low on the board);
# rx1 IQ as top.cst; HDMI as top.cst with P/N swapped (see the docstring).
BALL_NET = {
    # SDRAM
    "E3": "SD_CLK", "L10": "SD_RAS", "K10": "SD_CAS", "J7": "SD_WE",
    "L9": "SD_BA0", "K8": "SD_BA1",
    "F6": "SD_A0", "F7": "SD_A1", "J10": "SD_A2", "J11": "SD_A3", "K7": "SD_A4",
    "H2": "SD_A5", "H1": "SD_A6", "H4": "SD_A7", "G4": "SD_A8", "J2": "SD_A9",
    "J8": "SD_A10", "J1": "SD_A11", "D1": "SD_A12",
    "K2": "SD_DQ0", "K1": "SD_DQ1", "L1": "SD_DQ2", "L2": "SD_DQ3",
    "K4": "SD_DQ4", "J4": "SD_DQ5", "G1": "SD_DQ6", "G2": "SD_DQ7",
    "E1": "SD_DQ8", "A1": "SD_DQ9", "F2": "SD_DQ10", "F1": "SD_DQ11",
    "B2": "SD_DQ12", "C2": "SD_DQ13", "L4": "SD_DQ14", "L3": "SD_DQ15",
    # HDMI (P/N swapped)
    "H8": "TMDS0_N", "H7": "TMDS0_P", "G7": "TMDS1_N", "G8": "TMDS1_P",
    "F5": "TMDS2_N", "G5": "TMDS2_P", "H5": "TMDSC_N", "J5": "TMDSC_P",
    # receiver 1 (iq[0..7] = Q0 Q1 Q2 QS I0 I1 I2 IS)
    "C11": "R1_Q0", "C10": "R1_Q1", "B11": "R1_Q2", "B10": "R1_QS",
    "D11": "R1_I0", "D10": "R1_I1", "G11": "R1_I2", "G10": "R1_IS",
    # receiver 2
    "E11": "R2_Q0", "E10": "R2_Q1", "A11": "R2_Q2", "A10": "R2_QS",
    "K11": "R2_I0", "L11": "R2_I1", "L6": "R2_I2", "K6": "R2_IS",
    # receiver link: FPGA TX to both, RX from each
    "L5": "LINK_TX", "K5": "R1_TX", "K9": "R2_TX",
    # buttons (74HC165), LED
    "H11": "BTN_LD", "H10": "BTN_CLK", "L8": "BTN_Q", "L7": "LED_USER",
    # UART (FT2232 channel B), JTAG (channel A)
    "B3": "UART_RXD", "C3": "UART_TXD",
    "C1": "TCK", "B1": "TMS", "A2": "TDO", "A3": "TDI",
    # config
    "D7": "DONE", "D8": "RECONFIG_N",
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def place(lib, name, ref, x, y, deg, value, pins, hide=True):
    """pins: pad number -> net name; pads not listed stay unconnected."""
    fp = pcbnew.FootprintLoad(os.path.join(FPLIB, lib + ".pretty"), name)
    fp.SetReference(ref)
    fp.SetValue(value)
    fp.SetPosition(pt(x, y))
    fp.SetOrientationDegrees(deg)
    board.Add(fp)
    for p in fp.Pads():
        n = pins.get(p.GetNumber())
        if n:
            p.SetNet(net(n))
    if hide:
        fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    return fp


def R(ref, x, y, deg, value, a, b):
    return place("Resistor_SMD", "R_0402_1005Metric", ref, x, y, deg, value,
                 {"1": a, "2": b})


def C(ref, x, y, deg, value, a, b="GND", size="0402"):
    name = {"0402": "C_0402_1005Metric", "0805": "C_0805_2012Metric"}[size]
    return place("Capacitor_SMD", name, ref, x, y, deg, value, {"1": a, "2": b})


def FB(ref, x, y, deg, a, b):
    return place("Inductor_SMD", "L_0603_1608Metric", ref, x, y, deg,
                 "600R@100MHz", {"1": a, "2": b})


def LED(ref, x, y, deg, a, k):
    return place("LED_SMD", "LED_0603_1608Metric", ref, x, y, deg, "green",
                 {"2": a, "1": k})          # 1 = K


def pad_xy(fp, num):
    p = [p for p in fp.Pads() if p.GetNumber() == str(num)][0].GetPosition()
    return pcbnew.ToMM(p.x), pcbnew.ToMM(p.y)


def smd_pad(fp, num, x, y, w, h):
    p = pcbnew.PAD(fp)
    p.SetNumber(str(num))
    p.SetShape(pcbnew.PAD_SHAPE_ROUNDRECT)
    p.SetRoundRectRadiusRatio(0.25)
    p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
    p.SetLayerSet(pcbnew.PAD.SMDMask())
    p.SetSize(pcbnew.VECTOR2I(mm(w), mm(h)))
    fp.Add(p)
    p.SetPosition(pt(x, y))
    return p


def tht_pad(fp, num, x, y, size, drill):
    p = pcbnew.PAD(fp)
    p.SetNumber(str(num))
    p.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
    p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
    p.SetLayerSet(pcbnew.PAD.PTHMask())
    p.SetSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    p.SetDrillSize(pcbnew.VECTOR2I(mm(drill), mm(drill)))
    fp.Add(p)
    p.SetPosition(pt(x, y))
    return p


def fp_line(fp, x1, y1, x2, y2, layer, w=0.12):
    s = pcbnew.PCB_SHAPE(fp)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(layer)
    s.SetWidth(mm(w))
    fp.Add(s)
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))


def fp_rect(fp, x1, y1, x2, y2, layer, w=0.12):
    for a, b in [((x1, y1), (x2, y1)), ((x2, y1), (x2, y2)),
                 ((x2, y2), (x1, y2)), ((x1, y2), (x1, y1))]:
        fp_line(fp, *a, *b, layer, w)


# ---------------------------------------------------------------------------
# core module: DF40C-60DS-0.4V(51) x2, 14.0 mm apart, as on the Dock
# ---------------------------------------------------------------------------
CX, CY = 46.0, 28.0                     # centre of the core module
J2Y, J1Y = CY - 7.0, CY + 7.0           # J2 (pins 1/2 on the left) above J1


def df40(ref, x, y, ball, pwr):
    # odd pins in the upper row, even pins straight below; pin 1 on the left
    fp = pcbnew.FOOTPRINT(board)
    fp.SetFPID(pcbnew.LIB_ID("tang25k_base", "Hirose_DF40C-60DS-0.4V_2x30_P0.4mm"))
    fp.SetReference(ref)
    fp.SetValue("DF40C-60DS-0.4V(51)")
    board.Add(fp)
    fp.SetPosition(pt(x, y))
    for n in range(1, 61):
        k = (n - 1) // 2
        px = x - 5.8 + 0.4 * k
        py = y - 1.54 if n % 2 else y + 1.54
        p = smd_pad(fp, n, px, py, 0.2, 0.7)
        name = pwr.get(n) or BALL_NET.get(ball.get(n))
        if name:
            p.SetNet(net(name))
    fp_rect(fp, x - 7.0, y - 2.2, x + 7.0, y + 2.2, pcbnew.F_Fab)
    fp_line(fp, x - 7.1, y - 1.54, x - 7.1, y - 2.3, pcbnew.F_SilkS)   # pin 1
    fp_rect(fp, x - 7.25, y - 2.45, x + 7.25, y + 2.45, pcbnew.F_CrtYd, 0.05)
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    return fp


df40("J2", CX, J2Y, J2_BALL, J2_PWR)
df40("J1", CX, J1Y, J1_BALL, J1_PWR)

# outline of the module (22.9 x 17.8, centred on the connectors) on the silk
core = pcbnew.FOOTPRINT(board)
core.SetFPID(pcbnew.LIB_ID("tang25k_base", "Tang_Primer_25K_core_outline"))
core.SetReference("M1")
core.SetValue("Tang Primer 25K core")
board.Add(core)
core.SetPosition(pt(CX, CY))
# silk: corner marks only (the connector rows reach the module's edges)
for sx in (-1, 1):
    for sy in (-1, 1):
        x0, y0 = CX + sx * 11.45, CY + sy * 8.9
        fp_line(core, x0, y0, x0 - sx * 2.5, y0, pcbnew.F_SilkS, 0.15)
        fp_line(core, x0, y0, x0, y0 - sy * 2.5, pcbnew.F_SilkS, 0.15)
fp_rect(core, CX - 11.45, CY - 8.9, CX + 11.45, CY + 8.9, pcbnew.F_Fab, 0.1)
core.Reference().SetVisible(False)
core.Value().SetVisible(False)
core.SetAttributes(pcbnew.FP_BOARD_ONLY | pcbnew.FP_EXCLUDE_FROM_BOM | pcbnew.FP_EXCLUDE_FROM_POS_FILES)

# bulk and bank-supply parts just outside the module, right side
C("C1", 60.0, 21.5, 90, "22uF", "+5V", size="0805")
C("C2", 60.0, 25.0, 90, "22uF", "+3V3", size="0805")
FB("FB1", 33.0, 38.0, 0, "+3V3", "VCCIO01")
C("C3", 33.0, 39.4, 0, "100nF", "VCCIO01")
FB("FB2", 58.6, 31.0, 90, "+3V3", "VCCIO67")
C("C4", 58.6, 33.6, 90, "100nF", "VCCIO67")
FB("FB3", 32.4, 18.4, 0, "+3V3", "VCCIO23")
C("C5", 32.4, 19.9, 0, "100nF", "VCCIO23")

# ---------------------------------------------------------------------------
# SDRAM: W9825G6KH-6 (TSOP-II 54), pins 1..27 along the bottom row
# ---------------------------------------------------------------------------
SD = {1: "+3V3", 3: "+3V3", 9: "+3V3", 14: "+3V3", 27: "+3V3", 43: "+3V3", 49: "+3V3",
      6: "GND", 12: "GND", 28: "GND", 41: "GND", 46: "GND", 52: "GND", 54: "GND",
      15: "GND", 39: "GND", 19: "GND",            # LDQM, UDQM, CS#
      37: "+3V3",                                 # CKE
      38: "SD_CLK", 16: "SD_WE", 17: "SD_CAS", 18: "SD_RAS",
      20: "SD_BA0", 21: "SD_BA1", 22: "SD_A10", 23: "SD_A0", 24: "SD_A1",
      25: "SD_A2", 26: "SD_A3", 29: "SD_A4", 30: "SD_A5", 31: "SD_A6",
      32: "SD_A7", 33: "SD_A8", 34: "SD_A9", 35: "SD_A11", 36: "SD_A12",
      2: "SD_DQ0", 4: "SD_DQ1", 5: "SD_DQ2", 7: "SD_DQ3", 8: "SD_DQ4",
      10: "SD_DQ5", 11: "SD_DQ6", 13: "SD_DQ7", 42: "SD_DQ8", 44: "SD_DQ9",
      45: "SD_DQ10", 47: "SD_DQ11", 48: "SD_DQ12", 50: "SD_DQ13",
      51: "SD_DQ14", 53: "SD_DQ15"}
SDX, SDY = 46.0, 9.5
place("Package_SO", "TSOP-II-54_22.2x10.16mm_P0.8mm", "U3", SDX, SDY, 90,
      "W9825G6KH-6I", {str(k): v for k, v in SD.items()})
for i, x in enumerate((35.4, 40.5, 51.5, 56.6)):
    C(f"C{10 + i}", x, 1.3, 0, "100nF", "+3V3")
C("C14", 33.2, 9.5, 90, "10uF", "+3V3", size="0805")
C("C15", 58.8, 9.5, 90, "100nF", "+3V3")

# ---------------------------------------------------------------------------
# USB-C, ESD, fuse
# ---------------------------------------------------------------------------
usb = place("Connector_USB", "USB_C_Receptacle_HRO_TYPE-C-31-M-12", "J3", 4.0, 13.0, -90,
            "TYPE-C-31-M-12",
            {"A1": "GND", "B12": "GND", "A12": "GND", "B1": "GND",
             "A4": "VBUS", "B9": "VBUS", "A9": "VBUS", "B4": "VBUS",
             "A5": "CC1", "B5": "CC2", "A6": "USB_DP", "B6": "USB_DP",
             "A7": "USB_DM", "B7": "USB_DM", "S1": "GND"})
R("R1", 11.2, 4.4, 0, "5.1k", "CC1", "GND")
R("R2", 11.2, 17.8, 0, "5.1k", "CC2", "GND")
place("Fuse", "Fuse_1206_3216Metric", "F1", 4.0, 21.0, 0, "1.5A PTC",
      {"1": "VBUS", "2": "+5V"})
place("Package_TO_SOT_SMD", "SOT-23-6", "U6", 8.6, 23.6, 0, "USBLC6-2SC6",
      {"1": "USB_DP", "6": "USB_DP", "3": "USB_DM", "4": "USB_DM",
       "2": "GND", "5": "+5V"})
C("C6", 4.5, 25.2, 0, "10uF", "+5V", size="0805")

# ---------------------------------------------------------------------------
# FT2232HL: A = JTAG (ADBUS0 TCK, 1 TDI, 2 TDO, 3 TMS), B = UART
# ---------------------------------------------------------------------------
FT = {1: "GND", 5: "GND", 10: "GND", 11: "GND", 15: "GND", 25: "GND", 35: "GND",
      47: "GND", 51: "GND", 13: "GND",
      2: "XI", 3: "XO", 4: "VPHY", 9: "VPHY", 6: "FT_REF", 7: "USB_DM", 8: "USB_DP",
      12: "V1V8", 37: "V1V8", 64: "V1V8", 49: "V1V8",
      14: "+3V3", 20: "+3V3", 31: "+3V3", 42: "+3V3", 56: "+3V3", 50: "+3V3",
      16: "TCK", 17: "TDI", 18: "TDO", 19: "TMS",
      38: "UART_RXD", 39: "UART_TXD",          # BDBUS0 TXD -> FPGA, BDBUS1 RXD
      59: "FT_PWRSAV", 61: "EEDATA", 62: "EECLK", 63: "EECS"}
FTX, FTY = 20.0, 13.0
place("Package_QFP", "LQFP-64_10x10mm_P0.5mm", "U1", FTX, FTY, 0, "FT2232HL",
      {str(k): v for k, v in FT.items()})
place("Crystal", "Crystal_SMD_3225-4Pin_3.2x2.5mm", "Y1", 15.6, 4.2, 0, "12MHz",
      {"1": "XI", "3": "XO", "2": "GND", "4": "GND"})
C("C20", 14.5, 1.5, 0, "27pF", "XI")
C("C21", 16.7, 1.5, 0, "27pF", "XO")
R("R3", 11.2, 16.6, 0, "12k 1%", "FT_REF", "GND")
FB("FB4", 11.2, 7.2, 0, "+3V3", "VPHY")
C("C22", 11.2, 5.6, 0, "4.7uF", "VPHY")
C("C23", 11.2, 9.0, 0, "100nF", "VPHY")
C("C24", 29.4, 9.0, 90, "4.7uF", "V1V8")
C("C25", 27.6, 7.4, 0, "100nF", "V1V8")
C("C26", 28.0, 19.0, 90, "100nF", "V1V8")
C("C27", 15.5, 20.6, 0, "100nF", "+3V3")
C("C28", 26.0, 20.6, 0, "100nF", "+3V3")
C("C29", 28.0, 10.0, 90, "100nF", "+3V3")
C("C30", 28.0, 16.0, 90, "100nF", "+3V3")
C("C31", 20.0, 21.4, 0, "4.7uF", "+3V3")
R("R4", 23.5, 21.4, 0, "10k", "FT_PWRSAV", "+3V3")
R("R5", 20.0, 22.7, 0, "5.1k", "TCK", "GND")
# 93LC56B (SOIC-8): 1 CS, 2 CLK, 3 DI, 4 DO, 5 VSS, 6 ORG, 7 NC, 8 VCC
place("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm", "U2", 24.5, 3.4, 0, "93LC56B",
      {"1": "EECS", "2": "EECLK", "3": "EEDATA", "4": "EE_DO", "5": "GND",
       "6": "+3V3", "8": "+3V3"})
R("R6", 30.6, 1.6, 0, "2.2k", "EE_DO", "EEDATA")
R("R7", 30.6, 3.0, 0, "10k", "EE_DO", "+3V3")
C("C32", 30.6, 4.4, 0, "100nF", "+3V3")

# ---------------------------------------------------------------------------
# HDMI type A at the bottom edge, pin 1 (D2+) on the right
# ---------------------------------------------------------------------------
HX = 41.2
place("Connector_Video", "HDMI_A_Amphenol_10029449-x01xLF_Horizontal", "J4", HX, 45.6, 0,
      "HDMI A",
      {"1": "TMDS2_P", "2": "GND", "3": "TMDS2_N", "4": "TMDS1_P", "5": "GND",
       "6": "TMDS1_N", "7": "TMDS0_P", "8": "GND", "9": "TMDS0_N",
       "10": "TMDSC_P", "11": "GND", "12": "TMDSC_N", "17": "GND",
       "18": "HDMI_5V", "SH": "GND"})
place("Diode_SMD", "D_SOD-123", "D3", 30.0, 40.4, 90, "RB160M-30",
      {"1": "HDMI_5V", "2": "+5V"})

# ---------------------------------------------------------------------------
# buttons: six on a 74HC165, plus RECONFIG
# ---------------------------------------------------------------------------
BTN = [("SW1", 15.0, 30.0, "UP"), ("SW2", 15.0, 44.0, "DOWN"), ("SW3", 7.0, 37.0, "LEFT"),
       ("SW4", 23.0, 37.0, "RIGHT"), ("SW5", 15.0, 37.0, "OK"), ("SW6", 24.3, 45.2, "BACK")]
for i, (ref, x, y, _) in enumerate(BTN):
    place("Button_Switch_SMD", "SW_Push_1P1T_XKB_TS-1187A", ref, x, y, 0, "TS-1187A",
          {"1": f"BTN{i + 1}", "2": "GND"})
# 74HC165 (SOIC-16): 1 SH/LD#, 2 CLK, 3 E, 4 F, 5 G, 6 H, 7 QH#, 8 GND,
# 9 QH, 10 SER, 11 A, 12 B, 13 C, 14 D, 15 CLK INH, 16 VCC
place("Package_SO", "SOIC-16_3.9x9.9mm_P1.27mm", "U4", 29.0, 28.0, 0, "74HC165",
      {"1": "BTN_LD", "2": "BTN_CLK", "11": "BTN1", "12": "BTN2", "13": "BTN3",
       "14": "BTN4", "3": "BTN5", "4": "BTN6", "5": "+3V3", "6": "+3V3",
       "8": "GND", "9": "BTN_Q", "10": "+3V3", "15": "GND", "16": "+3V3"})
C("C33", 29.0, 22.0, 0, "100nF", "+3V3")
for i in range(6):
    R(f"R{10 + i}", 22.0 + 0 * i, 23.0 + 1.1 * i, 0, "10k", f"BTN{i + 1}", "+3V3")

place("Button_Switch_SMD", "SW_Push_1P1T_XKB_TS-1187A", "SW7", 66.0, 5.0, 0, "TS-1187A",
      {"1": "RECONFIG_N", "2": "GND"})
R("R16", 66.0, 9.0, 0, "10k", "RECONFIG_N", "+3V3")

# ---------------------------------------------------------------------------
# LEDs
# ---------------------------------------------------------------------------
LED("D10", 72.5, 3.0, 0, "LED_PWR", "GND")
R("R20", 72.5, 5.0, 0, "1k", "+3V3", "LED_PWR")
LED("D11", 76.0, 3.0, 0, "LED_DONE", "GND")
R("R21", 76.0, 5.0, 0, "1k", "DONE", "LED_DONE")
R("R22", 76.0, 6.4, 0, "10k", "DONE", "+3V3")
LED("D12", 79.5, 3.0, 0, "LED_USER_A", "GND")
R("R23", 79.5, 5.0, 0, "1k", "LED_USER", "LED_USER_A")

# ---------------------------------------------------------------------------
# XIAO ESP32-C5 x2 on 1x7 sockets, USB-C at the bottom edge
# ---------------------------------------------------------------------------
# Seeed coordinates (KiCad project "Seeed Studio XIAO ESP32C5 V1.1"): pins
# 1..7 (D0..D6) at y 65.078, D0 at the USB end (x 116.018); pins 8..14 (D7,
# D8, D9, D10, 3V3, GND, 5V) at y 80.318, 5V at the USB end. Turned so the
# USB end points down: Seeed +x -> board +y.
NX, NY = 108.398, 72.698
XIAO_Y = 38.5
XIAOS = [("R1", 69.0, "J5", "J6", "D1"), ("R2", 88.5, "J7", "J8", "D2")]


def xiao_xy(xc, xn, yn):
    dx, dy = xn - NX, yn - NY
    return round(xc - dy, 3), round(XIAO_Y + dx, 3)


def socket(ref, x, y_top, pin_nets):
    fp = place("Connector_PinSocket_2.54mm", "PinSocket_1x07_P2.54mm_Vertical", ref,
               x, y_top, 0, "1x7 socket", {})
    for p in fp.Pads():
        py = pcbnew.ToMM(p.GetPosition().y)
        name = pin_nets.get(round((py - y_top) / 2.54))
        if name:
            p.SetNet(net(name))
    return fp


for r, xc, ja, jb, dref in XIAOS:
    row_a = {116.018: f"{r}_Q0", 113.478: f"{r}_Q1", 110.938: f"{r}_Q2",
             108.398: f"{r}_QS", 105.858: f"{r}_TX", 103.318: "LINK_TX", 100.778: None}
    row_b = {100.778: None, 103.318: None, 105.858: None, 108.398: f"{r}_I0",
             110.938: None, 113.478: "GND", 116.018: f"{r}_VBUS"}
    xa = xiao_xy(xc, 0, 65.078)[0]
    xb = xiao_xy(xc, 0, 80.318)[0]
    y_top = xiao_xy(xc, 100.778, 0)[1]
    socket(ja, xa, y_top, {round((xiao_xy(xc, xn, 0)[1] - y_top) / 2.54): n
                           for xn, n in row_a.items()})
    socket(jb, xb, y_top, {round((xiao_xy(xc, xn, 0)[1] - y_top) / 2.54): n
                           for xn, n in row_b.items()})
    # wire holes under the XIAO's bottom-side pads MTDO / MTDI / MTCK
    for i, (sig, xn, yn) in enumerate([("I1", 117.043, 74.143), ("I2", 117.043, 71.603),
                                       ("IS", 111.963, 74.143)]):
        x, y = xiao_xy(xc, xn, yn)
        fp = pcbnew.FOOTPRINT(board)
        fp.SetFPID(pcbnew.LIB_ID("tang25k_base", "WireHole"))
        fp.SetReference(f"TP{r[1]}{i + 1}")
        board.Add(fp)
        fp.SetPosition(pt(x, y))
        tht_pad(fp, 1, x, y, 1.4, 0.8).SetNet(net(f"{r}_{sig}"))
        fp.Reference().SetVisible(False)
        fp.Value().SetVisible(False)
    # 5V to the XIAO through a Schottky (keeps its own USB VBUS out)
    place("Diode_SMD", "D_SOD-123", dref, xc, 25.0, 0, "RB160M-30",
          {"1": f"{r}_VBUS", "2": "+5V"})

# ---------------------------------------------------------------------------
# mounting holes, outline
# ---------------------------------------------------------------------------
for i, (x, y) in enumerate([(3.5, 3.5), (96.5, 3.5), (3.5, 46.5), (55.6, 46.5)]):
    place("MountingHole", "MountingHole_3.2mm_M3", f"H{i + 1}", x, y, 0, "M3", {})


# ---------------------------------------------------------------------------
# silkscreen
# ---------------------------------------------------------------------------
def text(s, x, y, size=0.8, deg=0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(pt(x, y))
    t.SetLayer(pcbnew.F_SilkS)
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    t.SetTextAngleDegrees(deg)
    board.Add(t)


for i, (ref, x, y, label) in enumerate(BTN):
    text(f"{label} ({i + 1})", x, y - 3.9)
text("RECONFIG", 66.0, 10.4)
text("PWR", 72.5, 1.4)
text("DONE", 76.0, 1.4)
text("USER", 79.5, 1.4)
text("USB JTAG/UART", 4.6, 19.2)
text("HDMI", HX, 38.6, 0.8)
text("TANG PRIMER 25K CORE", CX, CY, 1.0)
for r, xc, *_ in XIAOS:
    text(f"{r.replace('R', 'RX')}  XIAO ESP32-C5", xc, XIAO_Y - 10.4, 0.8)
    text("USB-C", xc, XIAO_Y + 8.0)
text("C5VRX Tang25K base v1", 84.0, 12.0, 1.0)


def edge(x1, y1, x2, y2):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(mm(0.1))
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))
    board.Add(s)


edge(0, 0, W, 0)
edge(W, 0, W, H)
edge(W, H, 0, H)
edge(0, H, 0, 0)

board.Save(OUT)

# net classes live in the project file: add PWR (0.4 mm) and its nets
PRO = OUT.replace(".kicad_pcb", ".kicad_pro")
with open(PRO, encoding="utf-8") as f:
    pro = json.load(f)
cls = pro["net_settings"]["classes"]
pwr = dict(cls[0], name="PWR", track_width=0.4, clearance=0.15,
           via_diameter=0.6, via_drill=0.3)
pro["net_settings"]["classes"] = [cls[0], pwr]
pro["net_settings"]["netclass_patterns"] = [
    {"netclass": "PWR", "pattern": n} for n in
    ["+5V", "VBUS", "R1_VBUS", "R2_VBUS", "HDMI_5V"]]
# thermal reliefs on the outer GND pours may end up with one spoke
pro["board"]["design_settings"]["rules"]["min_resolved_spokes"] = 1
with open(PRO, "w", encoding="utf-8") as f:
    json.dump(pro, f, indent=2)
print("saved", OUT, "nets", len(nets))
