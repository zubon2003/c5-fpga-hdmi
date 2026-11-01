"""Route tang25k_base.kicad_pcb: fixed HDMI traces, then Freerouting.

Run with KiCad 8's Python (it runs gen_base.py first, so the board is
always routed from scratch):
  "C:/Program Files/KiCad/8.0/bin/python.exe" route.py [passes]

1. The four TMDS pairs are drawn by hand (straight, 45 degree fan-out from
   the J1 pads to the HDMI pins); the two link pins that sit between the
   clock and D0 pairs are left to Freerouting. The traces are locked.
2. The In1.Cu GND and In2.Cu +3V3 planes (net classes: gen_base.py).
3. Specctra DSN -> Freerouting 1.7 -> SES back into the board.
4. GND pours on F.Cu and B.Cu, zone fill, save.
"""
import os
import subprocess
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, "tang25k_base.kicad_pcb")
DSN = os.path.join(HERE, "tang25k_base.dsn")
SES = os.path.join(HERE, "tang25k_base.ses")
FR = os.path.expandvars(r"%LOCALAPPDATA%\freerouting")
PASSES = sys.argv[1] if len(sys.argv) > 1 else "40"

W, H = 100.0, 50.0
mm = pcbnew.FromMM


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


# start from a fresh, unrouted board
subprocess.run([sys.executable, os.path.join(HERE, "gen_base.py")], check=True)
board = pcbnew.LoadBoard(PCB)
nets = board.GetNetsByName()


def netof(name):
    return nets[name]


def pad_xy(ref, num):
    fp = board.FindFootprintByReference(ref)
    p = [p for p in fp.Pads() if p.GetNumber() == str(num)][0].GetPosition()
    return pcbnew.ToMM(p.x), pcbnew.ToMM(p.y)


def track(name, pts, width, layer=pcbnew.F_Cu):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(pt(x1, y1))
        t.SetEnd(pt(x2, y2))
        t.SetWidth(mm(width))
        t.SetLayer(layer)
        t.SetNet(netof(name))
        t.SetLocked(True)
        board.Add(t)


# ---- 1. TMDS pairs: J1 even pads -> HDMI pins -----------------------------
TMDS = {4: (12, "TMDSC_N"), 6: (10, "TMDSC_P"), 12: (9, "TMDS0_N"), 14: (7, "TMDS0_P"),
        16: (6, "TMDS1_N"), 18: (4, "TMDS1_P"), 20: (3, "TMDS2_N"), 22: (1, "TMDS2_P")}
for jpin, (hpin, name) in TMDS.items():
    fx, fy = pad_xy("J1", jpin)
    hx, hy = pad_xy("J4", hpin)
    y1 = fy + 0.7
    track(name, [(fx, fy), (fx, y1), (hx, y1 + abs(hx - fx)), (hx, hy)], 0.15)

# ---- 2. planes (net classes come from the project file) ---------------
def zone(layer, name, margin=0.3, prio=0):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(netof(name))
    z.SetLocalClearance(mm(0.2))
    z.SetMinThickness(mm(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(mm(0.25))
    z.SetThermalReliefSpokeWidth(mm(0.3))
    z.SetAssignedPriority(prio)
    o = z.Outline()
    o.NewOutline()
    for x, y in [(margin, margin), (W - margin, margin), (W - margin, H - margin),
                 (margin, H - margin)]:
        o.Append(mm(x), mm(y))
    board.Add(z)
    return z


# keep tracks and vias 0.45 mm off the board edge (Freerouting only knows
# the net clearance)
def keepout_band(x1, y1, x2, y2):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(True)
    z.SetDoNotAllowCopperPour(False)
    z.SetDoNotAllowPads(False)
    z.SetDoNotAllowFootprints(False)
    z.SetLayerSet(pcbnew.LSET.AllCuMask())
    o = z.Outline()
    o.NewOutline()
    for x, y in [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]:
        o.Append(mm(x), mm(y))
    board.Add(z)


E = 0.45
keepout_band(0, 0, W, E)
keepout_band(0, H - E, W, H)
keepout_band(0, 0, E, H)
keepout_band(W - E, 0, W, H)

zone(pcbnew.In1_Cu, "GND")
zone(pcbnew.In2_Cu, "+3V3")

board.Save(PCB)
board = pcbnew.LoadBoard(PCB)
assert pcbnew.ExportSpecctraDSN(board, DSN), "DSN export failed"
print("DSN written")

# ---- 3. Freerouting --------------------------------------------------------
if os.path.exists(SES):
    os.remove(SES)
cmd = [os.path.join(FR, "freerouting.exe"), "-de", DSN, "-do", SES, "-mp", PASSES, "-mt", "4"]
print(" ".join(cmd))
subprocess.run(cmd, check=True, timeout=3000)
assert os.path.exists(SES), "no SES from Freerouting"
assert pcbnew.ImportSpecctraSES(board, SES), "SES import failed"
board.Save(PCB)

# ---- 4. GND pours, fill ----------------------------------------------------
board = pcbnew.LoadBoard(PCB)
nets = board.GetNetsByName()
zone(pcbnew.F_Cu, "GND")
zone(pcbnew.B_Cu, "GND")
board.Save(PCB)
board = pcbnew.LoadBoard(PCB)
board.BuildConnectivity()
pcbnew.ZONE_FILLER(board).Fill(board.Zones())
board.Save(PCB)
print("routed and filled", PCB)
