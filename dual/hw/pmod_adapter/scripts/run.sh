#!/bin/bash
set -e
cd "$(dirname "$0")"
export KICAD7_FOOTPRINT_DIR=/usr/share/kicad/footprints KICAD7_SYMBOL_DIR=/usr/share/kicad/symbols
python3 gen_lib.py out
python3 gen_sch.py out
kicad-cli sch export netlist --format kicadxml -o out/net.xml out/c5vrx_pmod_adapter.kicad_sch >/dev/null
python3 check_net.py out/net.xml
python3 gen_pcb.py out >/dev/null
python3 -c "import pcbnew; b=pcbnew.LoadBoard('out/c5vrx_pmod_adapter.kicad_pcb'); print('dsn', pcbnew.ExportSpecctraDSN(b,'out/adapter.dsn'))"
(cd out && java -jar /tmp/claude-0/tools/fr2.jar -de adapter.dsn -do adapter.ses -mp 100 -mt 1 --router.optimizer.enabled=false --gui.enabled=false > logs/fr.log 2>&1)
python3 finish_pcb.py out
