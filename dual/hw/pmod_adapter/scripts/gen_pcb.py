"""Build the PCB with pcbnew: footprints, nets, placement, outline, DSN export."""
import json
import os
import sys

import pcbnew

from design import BOARD_H, BOARD_W, PARTS, PROJECT

out = sys.argv[1]
stage = sys.argv[2] if len(sys.argv) > 2 else "place"
FPDIR = "/usr/share/kicad/footprints"
smap = json.load(open(os.path.join(out, "sch_map.json")))

mm = pcbnew.FromMM
OX, OY = 100.0, 80.0  # board origin on the sheet


def P(x, y):
    return pcbnew.VECTOR2I(mm(OX + x), mm(OY + y))


board = pcbnew.BOARD()
ds = board.GetDesignSettings()
ds.SetCopperLayerCount(2)
ds.m_TrackMinWidth = mm(0.15)
ds.m_ViasMinSize = mm(0.5)
ds.m_MinThroughDrill = mm(0.3)
ds.m_MinClearance = mm(0.15)
ds.m_CopperEdgeClearance = mm(0.3)
ds.m_HoleToHoleMin = mm(0.25)
ds.m_HoleClearance = mm(0.25)

nc = board.GetNetClasses() if hasattr(board, "GetNetClasses") else None
netsettings = ds.m_NetSettings
default = netsettings.m_DefaultNetClass
default.SetClearance(mm(0.18))
default.SetTrackWidth(mm(0.25))
default.SetViaDiameter(mm(0.6))
default.SetViaDrill(mm(0.3))

nets = {}


def net(name):
    if name not in nets:
        ni = pcbnew.NETINFO_ITEM(board, name)
        board.Add(ni)
        nets[name] = ni
    return nets[name]


for ref, lib_id, value, fpname, pinnets, dnp, (x, y, rot, side), desc in PARTS:
    nick, name = fpname.split(":")
    libpath = os.path.join(out, "c5vrx.pretty") if nick == "c5vrx" else os.path.join(FPDIR, nick + ".pretty")
    fp = pcbnew.FootprintLoad(libpath, name)
    if fp is None:
        raise RuntimeError("footprint not found " + fpname)
    fp.SetFPID(pcbnew.LIB_ID(nick, name))
    fp.SetReference(ref)
    fp.SetValue(value)
    fp.SetPath(pcbnew.KIID_PATH("/" + smap["parts"][ref]["uuid"]))
    if dnp:
        fp.SetAttributes(fp.GetAttributes() | pcbnew.FP_EXCLUDE_FROM_BOM | pcbnew.FP_EXCLUDE_FROM_POS_FILES)
    board.Add(fp)
    fp.SetPosition(P(x, y))
    fp.SetOrientationDegrees(rot)
    if side == "B":
        fp.Flip(fp.GetPosition(), False)
    for pad in fp.Pads():
        n = pinnets.get(int(pad.GetNumber())) if pad.GetNumber().isdigit() else None
        if n:
            pad.SetNet(net(n))
    # keep the reference text small
    r = fp.Reference()
    r.SetTextSize(pcbnew.VECTOR2I(mm(0.8), mm(0.8)))
    r.SetTextThickness(mm(0.12))
    if ref not in ("J1", "J2", "J3", "TP1", "U1"):
        # dense parts under the socketed XIAO: designators go to the assembly (Fab) layer
        r.SetLayer(pcbnew.B_Fab if side == "B" else pcbnew.F_Fab)
    if ref == "J1":
        for g in list(fp.GraphicalItems()):
            if g.GetLayer() == pcbnew.F_SilkS and pcbnew.ToMM(g.GetBoundingBox().GetTop()) < OY + 0.2:
                g.SetLayer(pcbnew.F_Fab)
        r.SetPosition(P(17.8, 5.4))
    if ref == "U1":
        r.SetPosition(P(9.5, 14.7))

# board outline (rectangle)
edge = pcbnew.Edge_Cuts
rect = pcbnew.PCB_SHAPE(board)
rect.SetShape(pcbnew.SHAPE_T_RECT)
rect.SetStart(P(0, 0)); rect.SetEnd(P(BOARD_W, BOARD_H))
rect.SetLayer(edge); rect.SetWidth(mm(0.1))
board.Add(rect)

# keep tracks 0.4 mm away from the board edge (exported to the autorouter as keepouts)
KE = 0.4
for x0, y0, x1, y1 in ((0, 0, BOARD_W, KE), (0, BOARD_H - KE, BOARD_W, BOARD_H),
                       (0, 0, KE, BOARD_H), (BOARD_W - KE, 0, BOARD_W, BOARD_H)):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True); z.SetDoNotAllowTracks(True); z.SetDoNotAllowVias(True)
    z.SetDoNotAllowCopperPour(False); z.SetDoNotAllowPads(False); z.SetDoNotAllowFootprints(False)
    ls = pcbnew.LSET(); ls.AddLayer(pcbnew.F_Cu); ls.AddLayer(pcbnew.B_Cu); z.SetLayerSet(ls)
    ol = z.Outline(); ol.NewOutline()
    for px, py in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        ol.Append(mm(OX + px), mm(OY + py))
    board.Add(z)

# silkscreen notes
def text(t, x, y, layer=pcbnew.F_SilkS, size=0.8, mirror=False):
    tx = pcbnew.PCB_TEXT(board)
    tx.SetText(t); tx.SetPosition(P(x, y)); tx.SetLayer(layer)
    tx.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size))); tx.SetTextThickness(mm(0.15))
    if mirror:
        tx.SetMirrored(True)
    board.Add(tx)

for t, x in (("5V", 1.6), ("G", 4.14), ("CLK", 7.3), ("VID", 14.96), ("G", 17.5)):
    text(t, x, 12.95, size=0.8)
text("C5VRX Pmod revA", 9.5, 33.2, pcbnew.B_SilkS, 0.8, True)

ds.SetAuxOrigin(P(0, BOARD_H))  # drill/place origin: bottom-left corner
ds.SetGridOrigin(P(0, BOARD_H))
board.SetFileName(os.path.join(out, PROJECT + ".kicad_pcb"))
pcbnew.SaveBoard(os.path.join(out, PROJECT + ".kicad_pcb"), board)

# report pad positions of key parts for verification
for fp in board.GetFootprints():
    if fp.GetReference() in ("J1", "J2", "J3", "U1"):
        for pad in sorted(fp.Pads(), key=lambda p: int(p.GetNumber())):
            pos = pad.GetPosition()
            print(fp.GetReference(), pad.GetNumber(), round(pcbnew.ToMM(pos.x) - OX, 2), round(pcbnew.ToMM(pos.y) - OY, 2), pad.GetNetname())
