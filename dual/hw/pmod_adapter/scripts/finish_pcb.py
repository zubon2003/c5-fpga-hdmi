import sys, pcbnew
from design import BOARD_W, BOARD_H
out = sys.argv[1]
fn = out + '/c5vrx_pmod_adapter.kicad_pcb'
b = pcbnew.LoadBoard(fn)
from sexp import parse
ses = parse(open(out + '/adapter.ses').read())[0]
def kids(node, key):
    return [e for e in node if isinstance(e, list) and e and e[0] == key]
routes = kids(ses, 'routes')[0]
res = kids(routes, 'resolution')[0]
scale = 1000.0 * float(res[2])  # units per mm (resolution um N = N units per um)
def tonm(v):
    return int(round(float(v) / scale * 1e6))
layers = {'F.Cu': pcbnew.F_Cu, 'B.Cu': pcbnew.B_Cu}
ntr = nvia = 0
for netn in kids(kids(routes, 'network_out')[0], 'net'):
    ni = b.FindNet(netn[1])
    for w in kids(netn, 'wire'):
        path = kids(w, 'path')[0]
        layer, width = layers[path[1]], tonm(path[2])
        c = path[3:]
        pts = [(tonm(c[i]), -tonm(c[i + 1])) for i in range(0, len(c) - 1, 2)]
        for a, bb in zip(pts, pts[1:]):
            t = pcbnew.PCB_TRACK(b); t.SetStart(pcbnew.VECTOR2I(*a)); t.SetEnd(pcbnew.VECTOR2I(*bb))
            t.SetWidth(width); t.SetLayer(layer); t.SetNet(ni); b.Add(t); ntr += 1
    for v in kids(netn, 'via'):
        via = pcbnew.PCB_VIA(b); via.SetPosition(pcbnew.VECTOR2I(tonm(v[2]), -tonm(v[3])))
        via.SetWidth(pcbnew.FromMM(0.6)); via.SetDrill(pcbnew.FromMM(0.3)); via.SetNet(ni)
        via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu); b.Add(via); nvia += 1
print('imported tracks', ntr, 'vias', nvia)
# drop duplicate segments (same layer, same endpoints in either direction)
seen=set()
for t in [t for t in b.GetTracks() if t.Type()==pcbnew.PCB_TRACE_T]:
    a,c=(t.GetStart().x,t.GetStart().y),(t.GetEnd().x,t.GetEnd().y)
    k=(t.GetLayer(),t.GetNetCode())+tuple(sorted([a,c]))
    if k in seen or a==c: b.Remove(t)
    else: seen.add(k)
# drop dangling stubs: track ends touching nothing (pad, via, other track)
for _ in range(5):
    tr=[t for t in b.GetTracks() if t.Type()==pcbnew.PCB_TRACE_T]
    vias=[t for t in b.GetTracks() if t.Type()==pcbnew.PCB_VIA_T]
    pads=list(b.GetPads()); removed=0
    for t in tr:
        for p in (t.GetStart(), t.GetEnd()):
            hit=any(o is not t and o.GetNetCode()==t.GetNetCode() and o.GetLayer()==t.GetLayer() and (o.GetStart()==p or o.GetEnd()==p) for o in tr)
            hit=hit or any(v.GetNetCode()==t.GetNetCode() and v.GetPosition()==p for v in vias)
            hit=hit or any(pd.GetNetCode()==t.GetNetCode() and pd.IsOnLayer(t.GetLayer()) and pd.HitTest(p) for pd in pads)
            if not hit:
                b.Remove(t); removed+=1; break
    print('removed dangling', removed)
    if not removed: break
mm = pcbnew.FromMM; OX, OY = 100.0, 80.0
gnd = b.FindNet('GND')
for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(b)
    z.SetLayer(layer); z.SetNet(gnd)
    z.SetLocalClearance(mm(0.25)); z.SetMinThickness(mm(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    z.SetThermalReliefGap(mm(0.3)); z.SetThermalReliefSpokeWidth(mm(0.3))
    ol = z.Outline(); ol.NewOutline()
    for x, y in [(0.3, 0.3), (BOARD_W - 0.3, 0.3), (BOARD_W - 0.3, BOARD_H - 0.3), (0.3, BOARD_H - 0.3)]:
        ol.Append(mm(OX + x), mm(OY + y))
    b.Add(z)
pcbnew.ZONE_FILLER(b).Fill(b.Zones())
pcbnew.SaveBoard(fn, b)
print('tracks', len(b.GetTracks()))
ok = pcbnew.WriteDRCReport(b, out + '/drc.rpt', pcbnew.EDA_UNITS_MILLIMETRES, True)
print('drc written', ok)
