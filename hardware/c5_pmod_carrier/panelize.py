"""Panelize c5_pmod_carrier.kicad_pcb for V-cut: COLS x ROWS boards
butted together (no gap), with plain rails on the top and bottom edge.

Run after gen_board.py, with KiCad 8's Python:
  "C:/Program Files/KiCad/8.0/bin/python.exe" panelize.py

Edge.Cuts holds the panel outline and the V-cut lines, each straight
across the whole panel, with a "V-CUT" label outside the panel at each
line (JLCPCB wants V-cuts on the outline layer, marked "V-CUT");
Cmts.User repeats the lines and labels. Copper keeps 0.5 mm from every board
edge (the board's edge clearance), so 0.25 mm on each side of the cut is
left clear. The copies share net names, so DRC on the panel reports the
copies as unconnected; check DRC on the single board instead.
"""
import os

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "c5_pmod_carrier.kicad_pcb")
OUT = os.path.join(HERE, "c5_pmod_carrier_panel.kicad_pcb")

COLS, ROWS = 4, 2
RAIL = 5.0

mm = pcbnew.FromMM


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


board = pcbnew.LoadBoard(SRC)

# single board extent from its Edge.Cuts
# (the end points, not the bounding box, which includes the line width)
edges = [d for d in board.GetDrawings() if d.GetLayer() == pcbnew.Edge_Cuts]
xs = [pcbnew.ToMM(p.x) for e in edges for p in (e.GetStart(), e.GetEnd())]
ys = [pcbnew.ToMM(p.y) for e in edges for p in (e.GetStart(), e.GetEnd())]
x0, y0 = min(xs), min(ys)
w, h = round(max(xs) - x0, 3), round(max(ys) - y0, 3)
for e in edges:
    board.Remove(e)

items = (list(board.GetFootprints()) + list(board.GetTracks()) +
         list(board.GetDrawings()) + list(board.Zones()))
for r in range(ROWS):
    for c in range(COLS):
        if r == 0 and c == 0:
            continue
        off = pt(c * w, r * h)
        for it in items:
            dup = it.Duplicate()
            board.Add(dup)
            dup.Move(off)


def line(x1, y1, x2, y2, layer, width=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(layer)
    s.SetWidth(mm(width))
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))
    board.Add(s)


def text(s, x, y, layer, size=1.0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(pt(x, y))
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    board.Add(t)


L, R = x0, x0 + COLS * w
T, B = y0 - RAIL, y0 + ROWS * h + RAIL
for a, b in [((L, T), (R, T)), ((R, T), (R, B)), ((R, B), (L, B)), ((L, B), (L, T))]:
    line(*a, *b, pcbnew.Edge_Cuts)

# V-cuts: between the columns, and every row edge (rails included)
vx = [x0 + c * w for c in range(1, COLS)]
vy = [y0 + r * h for r in range(0, ROWS + 1)]
for x in vx:
    line(x, T, x, B, pcbnew.Edge_Cuts)
    line(x, T - 2, x, B + 2, pcbnew.Cmts_User, 0.2)
    for layer in (pcbnew.Edge_Cuts, pcbnew.Cmts_User):
        text("V-CUT", x, T - 3, layer)
for y in vy:
    line(L, y, R, y, pcbnew.Edge_Cuts)
    line(L - 2, y, R + 2, y, pcbnew.Cmts_User, 0.2)
    for layer in (pcbnew.Edge_Cuts, pcbnew.Cmts_User):
        text("V-CUT", R + 6, y, layer)
text("V-CUT on all inner lines, %d x %d, %.1f x %.1f mm" % (COLS, ROWS, R - L, B - T),
     (L + R) / 2, B + 3, pcbnew.Cmts_User)
# rails: a label on the silkscreen only, no copper
text("C5VRX PMOD carrier v3  %dx%d V-CUT" % (COLS, ROWS), (L + R) / 2, T + RAIL / 2,
     pcbnew.F_SilkS)

board.Save(OUT)
board = pcbnew.LoadBoard(OUT)
board.BuildConnectivity()
filler = pcbnew.ZONE_FILLER(board)
filler.Fill(board.Zones())
board.Save(OUT)
print("saved", OUT, "%.1f x %.1f mm" % (R - L, B - T))
