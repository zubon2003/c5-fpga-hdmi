import sys, xml.etree.ElementTree as ET
from design import PARTS
t = ET.parse(sys.argv[1]).getroot()
got = {}
for net in t.find('nets'):
    name = net.get('name').lstrip('/')
    for node in net.findall('node'):
        got[(node.get('ref'), node.get('pin'))] = name
bad = 0
for ref, lib, val, fp, pins, dnp, pcb, d in PARTS:
    for p, n in pins.items():
        g = got.get((ref, str(p)))
        if n is None:
            if g and not g.startswith('unconnected-'):
                print('EXPECT NC', ref, p, g); bad += 1
        elif g != n:
            print('MISMATCH', ref, p, 'want', n, 'got', g); bad += 1
# every net must have >=2 pins
from collections import Counter
c = Counter(v for v in got.values())
for n, k in c.items():
    if k < 2 and not n.startswith('unconnected-') and n != 'OPT_CLK':
        print('SINGLE-PIN NET', n); bad += 1
print('nets:', len(c), 'errors:', bad)
