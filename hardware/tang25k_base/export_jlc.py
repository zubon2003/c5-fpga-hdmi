"""JLCPCB fabrication + assembly files for tang25k_base.kicad_pcb.

Run with KiCad 8's Python:
  "C:/Program Files/KiCad/8.0/bin/python.exe" export_jlc.py

Writes jlcpcb/:
  tang25k_base_gerber.zip   Gerbers + Excellon drill (upload as the PCB)
  tang25k_base_bom.csv      Comment, Designator, Footprint, LCSC
  tang25k_base_cpl.csv      Designator, Mid X, Mid Y, Layer, Rotation

Not assembled (no LCSC number): mounting holes, the core module outline,
the XIAO wire holes and the 1x7 XIAO sockets (through-hole, hand solder).
Check the rotations in JLCPCB's placement preview; some library parts are
drawn with a different zero angle than KiCad's footprints.
"""
import csv
import os
import shutil
import subprocess
import zipfile

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, "tang25k_base.kicad_pcb")
OUT = os.path.join(HERE, "jlcpcb")
GERB = os.path.join(OUT, "gerber")
CLI = r"C:\Program Files\KiCad\8.0\bin\kicad-cli.exe"
NAME = "tang25k_base"

# value -> LCSC part (JLCPCB parts library)
LCSC = {
    "100nF": "C1525",
    "4.7uF": "C23733",
    "10uF": "C15850",
    "22uF": "C45783",
    "27pF": "C1557",
    "5.1k": "C25905",
    "1k": "C11702",
    "10k": "C25744",
    "12k 1%": "C25752",
    "2.2k": "C25879",
    "green": "C72043",
    "600R@100MHz": "C1015",
    "1.5A PTC": "C20802",           # Ruilon SMD1206P150TF
    "RB160M-30": "C323857",         # RB160MM-30TR (RB160M-30 is not for new designs)
    "12MHz": "C9002",
    "USBLC6-2SC6": "C7519",
    "74HC165": "C5613",
    "93LC56B": "C183620",
    "FT2232HL": "C27882",
    "W9825G6KH-6I": "C97572",
    "DF40C-60DS-0.4V(51)": "C597938",
    "TYPE-C-31-M-12": "C165948",
    "HDMI A": "C427307",            # Amphenol 10029449-111RLF
    "TS-1187A": "C318884",
}
SKIP_PREFIX = ("H", "M", "TP")
SKIP_VALUE = ("1x7 socket",)

os.makedirs(GERB, exist_ok=True)
for f in os.listdir(GERB):
    os.remove(os.path.join(GERB, f))

# ---- Gerbers and drill ------------------------------------------------------
LAYERS = "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts"
subprocess.run([CLI, "pcb", "export", "gerbers", "--layers", LAYERS, "--subtract-soldermask",
                "--no-x2", "--no-netlist", "--use-drill-file-origin", "-o", GERB + os.sep, PCB],
               check=True)
subprocess.run([CLI, "pcb", "export", "drill", "--format", "excellon", "--drill-origin", "absolute",
                "--excellon-units", "mm", "--excellon-separate-th", "--generate-map",
                "--map-format", "gerberx2", "-o", GERB + os.sep, PCB], check=True)
zpath = os.path.join(OUT, NAME + "_gerber.zip")
with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(GERB)):
        z.write(os.path.join(GERB, f), f)

# ---- BOM and CPL ------------------------------------------------------------
board = pcbnew.LoadBoard(PCB)
groups = {}
cpl = []
missing = []
for fp in board.GetFootprints():
    ref, val = fp.GetReference(), fp.GetValue()
    if ref.startswith(SKIP_PREFIX) or val in SKIP_VALUE:
        continue
    if val not in LCSC:
        missing.append(ref)
        continue
    fpname = str(fp.GetFPID().GetUniStringLibItemName())
    groups.setdefault((val, fpname), []).append(ref)
    pos = fp.GetPosition()
    side = "Bottom" if fp.IsFlipped() else "Top"
    cpl.append((ref, pcbnew.ToMM(pos.x), -pcbnew.ToMM(pos.y), side,
                fp.GetOrientationDegrees() % 360))


def refkey(r):
    head = r.rstrip("0123456789")
    return head, int(r[len(head):] or 0)


with open(os.path.join(OUT, NAME + "_bom.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC"])
    for (val, fpname), refs in sorted(groups.items(), key=lambda kv: refkey(min(kv[1], key=refkey))):
        w.writerow([val, ",".join(sorted(refs, key=refkey)), fpname, LCSC[val]])

with open(os.path.join(OUT, NAME + "_cpl.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for ref, x, y, side, rot in sorted(cpl, key=lambda c: refkey(c[0])):
        w.writerow([ref, f"{x:.4f}mm", f"{y:.4f}mm", side, f"{rot:.0f}"])

print("gerber zip:", zpath)
print("parts placed:", len(cpl), "lines:", len(groups))
if missing:
    print("no LCSC number:", ",".join(missing))
