"""Generate the XIAO ESP32-C5 -> Tang Primer 25K Dock PMOD carrier.

Run with KiCad 8's Python:
  "C:/Program Files/KiCad/8.0/bin/python.exe" gen_board.py

Board coordinates are mm, origin at the top-left corner, y down. The PMOD
plug is on the top edge and points up (towards the Dock); the board lies
level with the Dock, component side up.

Dock PMOD numbering (schematic Tang_Primer_25K_Dock_60033): 1/2 = +3V3,
3/4 = GND, 5..12 signals; odd pins in the upper row, pins 1/2 on the left
when looking into the Dock socket from outside. On the carrier (top view,
plug at the top) that puts pins 1/2 on the left and the odd row furthest
from the edge. The XIAO pin and pad positions come from Seeed's
"Seeed Studio XIAO ESP32C5 V1.1" KiCad project (2025-12-25).

v3: the XIAO is turned 90 degrees clockwise (top view), antenna towards
the PMOD plug and USB-C pointing away from the Dock, so it fits the 20 mm
board width.

The PMOD pin order is chosen so that every trace is on F.Cu and none
cross; B.Cu is a solid ground plane. top.cst maps the IQ bits to match:
  PMOD 5 I1 (MTDO)  6 I0 (D10)     7 I2 (MTDI)   8 I sign (MTCK)
       9 Q1 (D1)   10 Q0 (D0)     11 Q sign (D3) 12 Q2 (D2)
"""
import math
import os

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
FPLIB = "C:/Program Files/KiCad/8.0/share/kicad/footprints"
OUT = os.path.join(HERE, "c5_pmod_carrier.kicad_pcb")

XL, XR = 11.8, 31.8                 # 20 mm wide
H = 36.0
TRACK = 0.25
POWER = 0.5

mm = pcbnew.FromMM


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


board = pcbnew.BOARD()
ds = board.GetDesignSettings()
ds.SetCopperLayerCount(2)
ds.m_TrackMinWidth = mm(0.2)
ds.m_MinClearance = mm(0.2)
ds.m_ViasMinSize = mm(0.6)
ds.m_MinThroughDrill = mm(0.3)
ds.m_HoleToHoleMin = mm(0.25)
nc = ds.m_NetSettings.m_DefaultNetClass
nc.SetClearance(mm(0.2))
nc.SetTrackWidth(mm(TRACK))
nc.SetViaDiameter(mm(0.6))
nc.SetViaDrill(mm(0.3))

nets = {}


def net(name):
    if name not in nets:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    return nets[name]


for n in ["GND", "+5V_IN", "VBUS", "Q0", "Q1", "Q2", "QS",
          "I0", "I1", "I2", "IS", "C5_TX", "C5_RX"]:
    net(n)

# ---- XIAO: two 1x7 sockets on 15.24 mm rows ------------------------------
# Seeed board, top view: pins 1..7 (D0..D6) in one row with D0 at the USB
# end, pins 8..14 (D7..D10, 3V3, GND, 5V/VBUS) in the other, pin 14 at the
# USB end. Turned 90 degrees clockwise on the carrier: USB end at the
# bottom, pins 1..7 in the right column, pins 8..14 in the left one.
XC, YC = 21.5, 17.02                # centre of the XIAO on the carrier
NX, NY = 108.398, 72.698            # centre in Seeed's coordinates


def xiao(xn, yn):
    dx, dy = xn - NX, yn - NY       # Seeed offsets, y down
    return round(XC - dy, 3), round(YC + dx, 3)


ROW_A = [("Q0", 116.018), ("Q1", 113.478), ("Q2", 110.938), ("QS", 108.398),
         ("C5_TX", 105.858), ("C5_RX", 103.318), (None, 100.778)]
ROW_B = [(None, 100.778), (None, 103.318), (None, 105.858), ("I0", 108.398),
         (None, 110.938), ("GND", 113.478), ("VBUS", 116.018)]
pin_net = {}
for name, xn in ROW_A:
    pin_net[xiao(xn, 65.078)] = name
for name, xn in ROW_B:
    pin_net[xiao(xn, 80.318)] = name

# bottom-side JTAG pads of the XIAO -> plated holes for the wires
TP = {"I1": xiao(117.043, 74.143),   # MTDO, GPIO5
      "I2": xiao(117.043, 71.603),   # MTDI, GPIO3
      "IS": xiao(111.963, 74.143)}   # MTCK, GPIO4


def place_lib(lib, name, ref, x, y, deg):
    fp = pcbnew.FootprintLoad(os.path.join(FPLIB, lib), name)
    fp.SetReference(ref)
    fp.SetPosition(pt(x, y))
    fp.SetOrientationDegrees(deg)
    board.Add(fp)
    return fp


def socket_col(ref, x, ys):
    # PinSocket_1x07 runs along +y at 0 degrees
    fp = place_lib("Connector_PinSocket_2.54mm.pretty",
                   "PinSocket_1x07_P2.54mm_Vertical", ref, x, min(ys), 0)
    got = sorted(pcbnew.ToMM(p.GetPosition().y) for p in fp.Pads())
    if abs(got[0] - min(ys)) > 0.01:          # it ran the other way
        fp.SetOrientationDegrees(180)
    for p in fp.Pads():
        key = (round(pcbnew.ToMM(p.GetPosition().x), 3),
               round(pcbnew.ToMM(p.GetPosition().y), 3))
        name = pin_net[min(pin_net, key=lambda k: (k[0] - key[0]) ** 2 + (k[1] - key[1]) ** 2)]
        if name:
            p.SetNet(net(name))
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    return fp


xa = xiao(0, 65.078)[0]             # right column (pins 1..7)
xb = xiao(0, 80.318)[0]             # left column (pins 8..14)
ys = sorted(xiao(x, 0)[1] for _, x in ROW_A)
socket_col("J2", xa, ys)
socket_col("J3", xb, ys)

# ---- PMOD plug: 2x6 right-angle male header, custom footprint -------------
COL1 = 15.42
ODD_Y, EVEN_Y = 6.6, 4.06           # odd row furthest from the top edge
PMOD = {1: None, 2: None, 3: "GND", 4: "GND", 5: "I1", 6: "I0", 7: "I2",
        8: "IS", 9: "Q1", 10: "Q0", 11: "QS", 12: "Q2"}


def pmod_xy(n):
    col = (n - 1) // 2
    return COL1 + 2.54 * col, (ODD_Y if n % 2 else EVEN_Y)


def tht_pad(fp, num, x, y, size, drill, square=False):
    p = pcbnew.PAD(fp)
    p.SetNumber(str(num))
    p.SetShape(pcbnew.PAD_SHAPE_RECT if square else pcbnew.PAD_SHAPE_CIRCLE)
    p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
    p.SetLayerSet(pcbnew.PAD.PTHMask())
    p.SetSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    p.SetDrillSize(pcbnew.VECTOR2I(mm(drill), mm(drill)))
    fp.Add(p)
    p.SetPosition(pt(x, y))
    return p


def silk_line(fp, x1, y1, x2, y2, layer=pcbnew.F_SilkS, w=0.15):
    s = pcbnew.PCB_SHAPE(fp)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(layer)
    s.SetWidth(mm(w))
    fp.Add(s)
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))


def silk_rect(fp, x1, y1, x2, y2, layer=pcbnew.F_SilkS, w=0.15):
    silk_line(fp, x1, y1, x2, y1, layer, w)
    silk_line(fp, x2, y1, x2, y2, layer, w)
    silk_line(fp, x2, y2, x1, y2, layer, w)
    silk_line(fp, x1, y2, x1, y1, layer, w)


pm = pcbnew.FOOTPRINT(board)
pm.SetFPID(pcbnew.LIB_ID("carrier", "PMOD_2x06_RightAngle_Male"))
pm.SetReference("J1")
pm.SetValue("PMOD 2x6 R/A male")
board.Add(pm)
pm.SetPosition(pt(0, 0))
for n, name in PMOD.items():
    x, y = pmod_xy(n)
    p = tht_pad(pm, n, x, y, 1.7, 1.0, square=(n == 1))
    if name:
        p.SetNet(net(name))
# housing (2.54 thick) at the edge, pins beyond the edge
silk_rect(pm, COL1 - 1.27, 0.15, COL1 + 5 * 2.54 + 1.27, 2.56, pcbnew.F_Fab)
pm.Reference().SetVisible(False)
pm.Value().SetVisible(False)

# ---- wire pads ------------------------------------------------------------
# bottom edge, 2.54 mm apart, right to left: RX, TX, GND, 5V
PAD_Y = 29.9
PADS = [("J4", "C5_RX", 30.2, PAD_Y, 2.0, 1.0),
        ("J5", "C5_TX", 27.66, PAD_Y, 2.0, 1.0),
        ("J6", "GND", 25.12, PAD_Y, 2.0, 1.0),
        ("J7", "+5V_IN", 22.58, PAD_Y, 2.0, 1.0)]
for ref, name, x, y, size, drill in PADS:
    fp = pcbnew.FOOTPRINT(board)
    fp.SetFPID(pcbnew.LIB_ID("carrier", "WirePad"))
    fp.SetReference(ref)
    board.Add(fp)
    fp.SetPosition(pt(x, y))
    tht_pad(fp, 1, x, y, size, drill).SetNet(net(name))
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
for i, (name, (x, y)) in enumerate(sorted(TP.items())):
    fp = pcbnew.FOOTPRINT(board)
    fp.SetFPID(pcbnew.LIB_ID("carrier", "JTAGWireHole"))
    fp.SetReference(f"TP{i + 1}")
    board.Add(fp)
    fp.SetPosition(pt(x, y))
    tht_pad(fp, 1, x, y, 1.5, 0.8).SetNet(net(name))
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)

# ---- Schottky diode: Tang 5V -> XIAO 5V, blocks the XIAO's USB VBUS --------
d = place_lib("Diode_SMD.pretty", "D_SOD-123", "D1", 17.0, PAD_Y, 0)
d.SetValue("RB160M-30")
for p in d.Pads():
    p.SetNet(net("VBUS" if p.GetNumber() == "1" else "+5V_IN"))   # 1 = K
d.Reference().SetVisible(False)
d.Value().SetVisible(False)
dk = [p for p in d.Pads() if p.GetNumber() == "1"][0].GetPosition()
da = [p for p in d.Pads() if p.GetNumber() == "2"][0].GetPosition()
dk = (pcbnew.ToMM(dk.x), pcbnew.ToMM(dk.y))
da = (pcbnew.ToMM(da.x), pcbnew.ToMM(da.y))

# ---- tracks (all F.Cu) ----------------------------------------------------
# From the plug every signal runs straight down; at Y0 it moves at 45
# degrees to its lane between the socket columns. Left to right the lanes
# are I0, I1, IS, I2, Q0, Q1, Q2, QS: I0 turns left to its pin, the JTAG
# holes are in the middle, and the Q lanes turn right, the lowest pin
# first. RX and TX leave the right column outwards and run down the right
# edge to the wire pads.
X = lambda name: [k for k, v in pin_net.items() if v == name][0]
Y0 = 7.6


def lane(n, x_lane):
    # plug pin -> (straight down) -> 45 degree move to x_lane
    x, y = pmod_xy(n)
    pts = [(x, y)]
    if n % 2 == 0:                  # even row: step left between the odd pins
        x -= 1.27
        pts.append((x, y))
    pts.append((x, Y0))
    if abs(x - x_lane) > 1e-3:
        pts.append((x_lane, Y0 + abs(x - x_lane)))
    return pts


ROUTES = {
    "I0": lane(6, 18.1) + [(18.1, X("I0")[1]), X("I0")],
    "I1": lane(5, 18.9) + [(18.9, TP["I1"][1]), TP["I1"]],
    "IS": lane(8, TP["IS"][0]) + [TP["IS"]],
    "I2": lane(7, TP["I2"][0]) + [TP["I2"]],
    "Q0": lane(10, 25.2) + [(25.2, X("Q0")[1]), X("Q0")],
    "Q1": lane(9, 26.0) + [(26.0, X("Q1")[1]), X("Q1")],
    "Q2": lane(12, 26.85) + [(26.85, X("Q2")[1]), X("Q2")],
    "QS": lane(11, 27.6) + [(27.6, X("QS")[1]), X("QS")],
    "C5_RX": [X("C5_RX"), (30.8, X("C5_RX")[1]), (30.8, PAD_Y), (30.2, PAD_Y)],
    "C5_TX": [X("C5_TX"), (30.33, X("C5_TX")[1]), (30.33, 27.0), (27.66, 27.0),
              (27.66, PAD_Y)],
}
POWER_ROUTES = {
    "VBUS": [X("VBUS"), (X("VBUS")[0], PAD_Y), dk],
    "+5V_IN": [da, (22.58, PAD_Y)],
}


def chamfer(pts, c=1.0):
    # cut every right-angle corner to two 45 degree bends
    out = [pts[0]]
    for p0, p1, p2 in zip(pts, pts[1:], pts[2:]):
        a = (p1[0] - p0[0], p1[1] - p0[1])
        b = (p2[0] - p1[0], p2[1] - p1[1])
        la, lb = math.hypot(*a), math.hypot(*b)
        if la < 1e-6 or lb < 1e-6 or abs(a[0] * b[0] + a[1] * b[1]) > 0.1 * la * lb:
            out.append(p1)
            continue
        k = min(c, la / 2, lb / 2)
        out.append((p1[0] - a[0] / la * k, p1[1] - a[1] / la * k))
        out.append((p1[0] + b[0] / lb * k, p1[1] + b[1] / lb * k))
    out.append(pts[-1])
    merged = [out[0]]
    for q in out[1:]:
        if math.hypot(q[0] - merged[-1][0], q[1] - merged[-1][1]) > 1e-4:
            merged.append(q)
    return merged


def route(name, pts, width):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(pt(x1, y1))
        t.SetEnd(pt(x2, y2))
        t.SetWidth(mm(width))
        t.SetLayer(pcbnew.F_Cu)
        t.SetNet(net(name))
        board.Add(t)


for name, pts in ROUTES.items():
    route(name, chamfer(pts), TRACK)
for name, pts in POWER_ROUTES.items():
    route(name, chamfer(pts), POWER)

# ---- outline, ground planes, stitching vias -------------------------------
def edge(x1, y1, x2, y2):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(mm(0.1))
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))
    board.Add(s)


edge(XL, 0, XR, 0)
edge(XR, 0, XR, H)
edge(XR, H, XL, H)
edge(XL, H, XL, 0)

for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(net("GND"))
    z.SetLocalClearance(mm(0.3))
    z.SetMinThickness(mm(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(mm(0.3))
    z.SetThermalReliefSpokeWidth(mm(0.4))
    o = z.Outline()
    o.NewOutline()
    for x, y in [(XL + 0.3, 0.3), (XR - 0.3, 0.3), (XR - 0.3, H - 0.3), (XL + 0.3, H - 0.3)]:
        o.Append(mm(x), mm(y))
    board.Add(z)

for x, y in [(12.8, 1.5), (31.0, 1.5), (12.6, 10.67), (12.6, 20.83), (12.6, 27.0),
             (12.6, 31.3), (16.0, 21.5), (24.0, 21.0)]:
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(pt(x, y))
    v.SetWidth(mm(0.6))
    v.SetDrill(mm(0.3))
    v.SetNet(net("GND"))
    board.Add(v)

# ---- silkscreen -----------------------------------------------------------
def text(s, x, y, size=0.8, layer=pcbnew.F_SilkS, deg=0, mirror=False):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(pt(x, y))
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    t.SetTextAngleDegrees(deg)
    if mirror:
        t.SetMirrored(True)
    board.Add(t)


def gline(x1, y1, x2, y2, layer=pcbnew.F_SilkS, w=0.15):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(layer)
    s.SetWidth(mm(w))
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))
    board.Add(s)


text("1", COL1 - 2.0, ODD_Y, 0.8)
text("TO DOCK PMOD (J4 / J5)", 21.8, 1.3, 0.8, pcbnew.F_Fab)
text("RX", 30.2, 31.6, 0.8)
text("TX", 27.66, 31.6, 0.8)
text("GND", 25.12, 31.6, 0.8)
text("5V", 22.58, 31.6, 0.8)
text("D5", 30.2, 32.6, 0.8)
text("D4", 27.66, 32.6, 0.8)
text("K", dk[0], 31.6, 0.8)
LABEL = {"I1": ("MTDO", -2.45), "I2": ("MTDI", 2.5), "IS": ("MTCK", -2.45)}
for name, (x, y) in TP.items():
    lbl, dx = LABEL[name]
    text(lbl, x + dx, y, 0.8)
# XIAO outline (17.8 x 21, USB-C at the bottom) on F.Fab only; the sockets'
# own silk shows the columns
x1, x2 = XC - 8.9, XC + 8.9
y1, y2 = YC - 10.5, YC + 10.5
for a, b in [((x1, y1), (x2, y1)), ((x2, y1), (x2, y2)), ((x2, y2), (x1, y2)), ((x1, y2), (x1, y1))]:
    gline(a[0], a[1], b[0], b[1], pcbnew.F_Fab)
text("ANT", XC, 11.0, 0.9)
text("C5VRX carrier v3", XC, 14.0, 0.9)
text("USB-C", XC, 27.6, 0.9)
text("THIS SIDE UP", 21.8, 34.0, 0.8)
# back side: the JTAG wires come through these holes and are soldered here
for name, (x, y) in TP.items():
    lbl, dx = LABEL[name]
    text(lbl, x + dx, y, 0.8, pcbnew.B_SilkS, mirror=True)


# ---- logos on the back silkscreen -------------------------------------------
# The logo footprints (F.SilkS, centred on their origin) sit next to this
# script. They are scaled to fit the free areas and flipped to the back.
def logo(name, ref, x, y, width):
    fp = pcbnew.FootprintLoad(HERE, name)
    k = width / pcbnew.ToMM(fp.GetBoundingBox(False, False).GetWidth())
    for g in fp.GraphicalItems():
        g = g.Cast()
        g.Scale(k)                  # about the footprint origin; not the width
        g.SetWidth(round(g.GetWidth() * k))
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    board.Add(fp)
    fp.SetPosition(pt(x, y))
    fp.Flip(pt(x, y), True)         # mirrored left-right: reads from the back


# below the wire pads, full width
logo("LOGO_ZUBONTECH_RX5808v3_x2", "LOGO1", 21.8, 33.75, 18.0)
# round, between the socket columns, above the JTAG wire holes
logo("LOGO_TinywhoopLab_15mm", "LOGO2", XC, 13.9, 11.5)

board.Save(OUT)                     # the filler needs a board with a file
board = pcbnew.LoadBoard(OUT)
board.BuildConnectivity()
filler = pcbnew.ZONE_FILLER(board)
filler.Fill(board.Zones())
board.Save(OUT)

print("saved", OUT)
