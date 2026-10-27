"""Generate the KiCad 7 schematic: symbols placed on a grid, nets by labels."""
import copy
import json
import os
import sys
import uuid

from design import PARTS, PROJECT
from sexp import Sym, dump, find_symbol, parse

out = sys.argv[1]
SYMDIR = "/usr/share/kicad/symbols"
LIBS = {
    "Device": f"{SYMDIR}/Device.kicad_sym",
    "Connector_Generic": f"{SYMDIR}/Connector_Generic.kicad_sym",
    "Connector": f"{SYMDIR}/Connector.kicad_sym",
    "Jumper": f"{SYMDIR}/Jumper.kicad_sym",
    "c5vrx": os.path.join(out, "c5vrx.kicad_sym"),
}

root_uuid = str(uuid.uuid4())

# Schematic placement (mm, 2.54 grid) per reference.
SCH_POS = {
    "U1": (60.96, 63.5), "J1": (165.1, 63.5),
    "R1": (111.76, 45.72), "R2": (111.76, 53.34), "R3": (111.76, 60.96),
    "R4": (111.76, 68.58), "R5": (111.76, 76.2), "R6": (111.76, 83.82),
    "J2": (30.48, 121.92), "D1": (53.34, 119.38), "C1": (76.2, 124.46), "C2": (88.9, 124.46),
    "C3": (106.68, 124.46), "JP1": (127.0, 119.38), "TP1": (165.1, 101.6),
    "R10": (60.96, 165.1), "R11": (73.66, 165.1), "R12": (86.36, 165.1),
    "R13": (99.06, 165.1), "R14": (111.76, 165.1), "R15": (124.46, 165.1),
    "R16": (144.78, 165.1), "C4": (157.48, 165.1), "J3": (182.88, 162.56),
}
# Resistors in the series bank are drawn horizontally.
SCH_ROT = {r: 90 for r in ("R1", "R2", "R3", "R4", "R5", "R6")}

lib_cache = {}


def lib_symbol(lib_id):
    if lib_id in lib_cache:
        return lib_cache[lib_id]
    nick, name = lib_id.split(":")
    s = copy.deepcopy(find_symbol(LIBS[nick], name))
    if any(isinstance(e, list) and e and e[0] == "extends" for e in s):
        raise RuntimeError("extends not supported: " + lib_id)
    s[1] = lib_id
    lib_cache[lib_id] = s
    return s


def pins_of(sym):
    res = {}

    def walk(node):
        for e in node:
            if isinstance(e, list) and e:
                if e[0] == "pin":
                    at = next(x for x in e if isinstance(x, list) and x and x[0] == "at")
                    num = next(x for x in e if isinstance(x, list) and x and x[0] == "number")[1]
                    res[str(num)] = (float(at[1]), float(at[2]), float(at[3]) if len(at) > 3 else 0.0)
                elif e[0] == "symbol":
                    walk(e)
    walk(sym)
    return res


def rot(x, y, a):
    a %= 360
    if a == 0:
        return x, y
    if a == 90:
        return -y, x
    if a == 180:
        return -x, -y
    if a == 270:
        return y, -x
    raise ValueError(a)


def prop(name, value, x, y, hide=False):
    eff = [Sym("effects"), [Sym("font"), [Sym("size"), 1.27, 1.27]]]
    if hide:
        eff.append(Sym("hide"))
    return [Sym("property"), name, value, [Sym("at"), x, y, 0], eff]


items = []
labels = []
noconn = []
netmap = {}
for ref, lib_id, value, fp, pinnets, dnp, _pcb, desc in PARTS:
    sym = lib_symbol(lib_id)
    sx, sy = SCH_POS[ref]
    a = SCH_ROT.get(ref, 0)
    pins = pins_of(sym)
    inst = [Sym("symbol"), [Sym("lib_id"), lib_id], [Sym("at"), sx, sy, a], [Sym("unit"), 1],
            [Sym("in_bom"), Sym("yes")], [Sym("on_board"), Sym("yes")],
            [Sym("dnp"), Sym("yes" if dnp else "no")],
            [Sym("uuid"), str(uuid.uuid4())]]
    inst.append(prop("Reference", ref, sx + 2.54, sy - 3.81))
    inst.append(prop("Value", value, sx + 2.54, sy + 3.81))
    inst.append(prop("Footprint", fp, sx, sy, hide=True))
    inst.append(prop("Datasheet", "", sx, sy, hide=True))
    if desc:
        inst.append(prop("Description", desc, sx, sy, hide=True))
    sym_uuid = inst[7][1]
    for num in sorted(pins, key=lambda n: int(n) if n.isdigit() else 0):
        inst.append([Sym("pin"), num, [Sym("uuid"), str(uuid.uuid4())]])
    inst.append([Sym("instances"), [Sym("project"), PROJECT,
                 [Sym("path"), "/" + root_uuid, [Sym("reference"), ref], [Sym("unit"), 1]]]])
    items.append(inst)
    netmap[ref] = {"uuid": sym_uuid, "pins": {}}
    for num, (px, py, pa) in pins.items():
        rx, ry = rot(px, py, a)
        cx, cy = round(sx + rx, 4), round(sy - ry, 4)
        net = pinnets.get(int(num))
        netmap[ref]["pins"][num] = net
        if net is None:
            noconn.append([Sym("no_connect"), [Sym("at"), cx, cy], [Sym("uuid"), str(uuid.uuid4())]])
            continue
        # label points away from the symbol body
        la = (pa + a + 180) % 360
        just = [Sym("justify"), Sym("right")] if la in (180, 270) else [Sym("justify"), Sym("left")]
        labels.append([Sym("label"), net, [Sym("at"), cx, cy, la],
                       [Sym("effects"), [Sym("font"), [Sym("size"), 1.0, 1.0]], just],
                       [Sym("uuid"), str(uuid.uuid4())]])

notes = [
    "C5VRX Pmod adapter (1x XIAO ESP32-C5). Make two boards: XIAO-A on Dock Pmod J4, XIAO-B on J5.",
    "C5VRX outputs 6-bit CVBS on D4..D9 (20 MS/s). D0..D3 and D10 carry C5VRX's internal IQ loopback: leave unconnected.",
    "Power: 5V wire from the Dock's bottom-side debugger pad '5V' to J2 (D1 blocks back-feed when XIAO USB is plugged).",
    "JP1: close only to run from Pmod 3V3 instead of J2 (then never plug the XIAO USB while JP1 is closed).",
    "R10..R16, C4: optional analog CVBS DAC (C5VRX reference values), not populated by default.",
]
texts = []
for i, t in enumerate(notes):
    texts.append([Sym("text"), t, [Sym("at"), 25.4, 190.5 + i * 3.81, 0],
                  [Sym("effects"), [Sym("font"), [Sym("size"), 1.27, 1.27]], [Sym("justify"), Sym("left")]],
                  [Sym("uuid"), str(uuid.uuid4())]])

doc = [Sym("kicad_sch"), [Sym("version"), 20230121], [Sym("generator"), Sym("eeschema")],
       [Sym("uuid"), root_uuid], [Sym("paper"), "A4"],
       [Sym("title_block"), [Sym("title"), "C5VRX Pmod adapter"], [Sym("date"), "2026-10-06"],
        [Sym("rev"), "A"], [Sym("comment"), 1, "XIAO ESP32-C5 (C5VRX) -> Tang Primer 25K Dock Pmod"]],
       [Sym("lib_symbols")] + list(lib_cache.values())]
doc += items + labels + noconn + texts
doc.append([Sym("sheet_instances"), [Sym("path"), "/", [Sym("page"), "1"]]])

open(os.path.join(out, PROJECT + ".kicad_sch"), "w").write(dump(doc) + "\n")
json.dump({"root": root_uuid, "parts": netmap}, open(os.path.join(out, "sch_map.json"), "w"), indent=1)
print("schematic written", len(items), "symbols", len(labels), "labels", len(noconn), "no-connects")
