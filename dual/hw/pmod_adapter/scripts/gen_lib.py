"""Write the project's custom XIAO symbol and footprint."""
import os
import sys
import uuid

from design import XIAO_PINS

out = sys.argv[1]
os.makedirs(os.path.join(out, "c5vrx.pretty"), exist_ok=True)

# ---- symbol: pins 1-7 on the left, 14..8 on the right (top to bottom) ----
pins = []
for i in range(1, 8):
    name = XIAO_PINS[i][0]
    pins.append((i, name, -12.7, 7.62 - 2.54 * (i - 1), 0))
right = [14, 13, 12, 11, 10, 9, 8]
for k, p in enumerate(right):
    name = XIAO_PINS[p][0]
    typ = "power_in" if name in ("5V", "3V3", "GND") else "bidirectional"
    pins.append((p, name, 12.7, 7.62 - 2.54 * k, 180))

pin_txt = ""
for num, name, x, y, ang in pins:
    typ = "passive"
    pin_txt += f'''      (pin {typ} line (at {x} {y} {ang}) (length 2.54)
        (name "{name}" (effects (font (size 1.27 1.27))))
        (number "{num}" (effects (font (size 1.27 1.27))))
      )
'''

sym = f'''(kicad_symbol_lib (version 20220914) (generator c5vrx_gen)
  (symbol "XIAO_ESP32C5" (pin_names (offset 1.016)) (in_bom yes) (on_board yes)
    (property "Reference" "U" (at 0 11.43 0) (effects (font (size 1.27 1.27))))
    (property "Value" "XIAO_ESP32C5" (at 0 -11.43 0) (effects (font (size 1.27 1.27))))
    (property "Footprint" "c5vrx:XIAO_THT_Socket" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))
    (property "Datasheet" "https://wiki.seeedstudio.com/xiao_esp32c5_getting_started/" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))
    (symbol "XIAO_ESP32C5_0_1"
      (rectangle (start -10.16 10.16) (end 10.16 -10.16) (stroke (width 0.254) (type default)) (fill (type background)))
    )
    (symbol "XIAO_ESP32C5_1_1"
{pin_txt}    )
  )
)
'''
open(os.path.join(out, "c5vrx.kicad_sym"), "w").write(sym)

# ---- footprint: USB-up frame, origin at module centre ----
def tid():
    return str(uuid.uuid4())

pads = ""
for i in range(1, 8):  # left column, top to bottom
    x, y = -7.62, -7.62 + 2.54 * (i - 1)
    shape = "rect" if i == 1 else "circle"
    pads += f'  (pad "{i}" thru_hole {shape} (at {x} {y}) (size 1.7 1.7) (drill 1.0) (layers "*.Cu" "*.Mask") (tstamp {tid()}))\n'
for k, p in enumerate([14, 13, 12, 11, 10, 9, 8]):  # right column, top to bottom
    x, y = 7.62, -7.62 + 2.54 * k
    pads += f'  (pad "{p}" thru_hole circle (at {x} {y}) (size 1.7 1.7) (drill 1.0) (layers "*.Cu" "*.Mask") (tstamp {tid()}))\n'

def rect(layer, x0, y0, x1, y1, w):
    return (f'  (fp_line (start {x0} {y0}) (end {x1} {y0}) (layer "{layer}") (width {w}) (tstamp {tid()}))\n'
            f'  (fp_line (start {x1} {y0}) (end {x1} {y1}) (layer "{layer}") (width {w}) (tstamp {tid()}))\n'
            f'  (fp_line (start {x1} {y1}) (end {x0} {y1}) (layer "{layer}") (width {w}) (tstamp {tid()}))\n'
            f'  (fp_line (start {x0} {y1}) (end {x0} {y0}) (layer "{layer}") (width {w}) (tstamp {tid()}))\n')

fp = f'''(footprint "XIAO_THT_Socket" (version 20221018) (generator c5vrx_gen)
  (layer "F.Cu")
  (descr "Seeed Studio XIAO (21 x 17.8 mm), 2x7 THT 2.54mm, rows 15.24mm apart, for 1x7 female sockets. USB-C at the top (negative Y). Courtyard covers only the sockets; SMD parts may sit under the raised module.")
  (tags "XIAO Seeed ESP32-C5")
  (attr through_hole)
  (fp_text reference "REF**" (at 0 -12.6) (layer "F.SilkS") (effects (font (size 0.8 0.8) (thickness 0.12))) (tstamp {tid()}))
  (fp_text value "XIAO_THT_Socket" (at 0 12.0) (layer "F.Fab") (effects (font (size 0.8 0.8) (thickness 0.12))) (tstamp {tid()}))
  (fp_text user "USB-C" (at 0 -11.15) (layer "F.Fab") (effects (font (size 0.8 0.8) (thickness 0.12))) (tstamp {tid()}))
{rect("F.Fab", -8.9, -10.5, 8.9, 10.5, 0.1)}{rect("F.Fab", -4.5, -11.8, 4.5, -10.5, 0.1)}{rect("F.CrtYd", -9.14, -9.14, -6.1, 9.14, 0.05)}{rect("F.CrtYd", 6.1, -9.14, 9.14, 9.14, 0.05)}{rect("F.SilkS", -9.0, -10.6, 9.0, 9.8, 0.12)}{pads})
'''
open(os.path.join(out, "c5vrx.pretty", "XIAO_THT_Socket.kicad_mod"), "w").write(fp)
print("lib written")
