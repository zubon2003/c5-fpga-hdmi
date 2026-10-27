"""Single source of truth for the C5VRX Pmod adapter: parts, nets, placement."""

PROJECT = "c5vrx_pmod_adapter"

# Pmod J1 (KiCad Conn_02x06_Odd_Even / PinHeader_2x06 horizontal).
# Footprint rotated 90 deg: odd pins = upper (inner) row, even pins = lower row,
# pin 1/2 at the west end. Viewed from outside the dock looking into its Pmod
# socket, upper row west->east is 3V3, GND, IO4, IO3, IO2, IO1 (IO1 = G11 on J4).
J1_PINS = {
    1: "PMOD_3V3", 3: "GND", 5: "OPT_CLK", 7: "CVBS2", 9: "CVBS1", 11: "CVBS0",
    2: "PMOD_3V3", 4: "GND", 6: None, 8: "CVBS5", 10: "CVBS4", 12: "CVBS3",
}

# XIAO pin numbers: 1-7 = D0-D6 (left column, USB up), 8 = D7 ... 11 = D10,
# 12 = 3V3, 13 = GND, 14 = 5V.
XIAO_PINS = {
    1: ("D0", None), 2: ("D1", None), 3: ("D2", None), 4: ("D3", None),
    5: ("D4", "X_D4"), 6: ("D5", "X_D5"), 7: ("D6", "X_D6"),
    8: ("D7", "X_D7"), 9: ("D8", "X_D8"), 10: ("D9", "X_D9"), 11: ("D10", None),
    12: ("3V3", "+3V3_XIAO"), 13: ("GND", "GND"), 14: ("5V", "+5V_XIAO"),
}

FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_C06 = "Capacitor_SMD:C_0603_1608Metric"
FP_C08 = "Capacitor_SMD:C_0805_2012Metric"

# ref, lib_id, value, footprint, {pin: net}, dnp, pcb (x, y, rot, side), description
PARTS = [
    ("U1", "c5vrx:XIAO_ESP32C5", "XIAO ESP32-C5 (C5VRX)", "c5vrx:XIAO_THT_Socket",
     {p: n for p, (_, n) in XIAO_PINS.items()}, False, (9.5, 23.5, 180, "F"),
     "Seeed XIAO ESP32-C5 on 2x 1x7 female sockets"),
    ("J1", "Connector_Generic:Conn_02x06_Odd_Even", "Pmod (to Dock)",
     "Connector_PinHeader_2.54mm:PinHeader_2x06_P2.54mm_Horizontal",
     J1_PINS, False, (3.15, 6.64, 90, "F"), "2x6 right-angle male header 2.54mm"),
    ("R1", "Device:R", "33", FP_R, {1: "X_D4", 2: "CVBS0"}, False, (14.0, 20.96, 0, "F"), ""),
    ("R2", "Device:R", "33", FP_R, {1: "X_D5", 2: "CVBS1"}, False, (14.0, 18.42, 0, "F"), ""),
    ("R3", "Device:R", "33", FP_R, {1: "X_D6", 2: "CVBS2"}, False, (14.0, 15.88, 0, "F"), ""),
    ("R4", "Device:R", "33", FP_R, {1: "X_D7", 2: "CVBS3"}, False, (5.0, 15.88, 180, "F"), ""),
    ("R5", "Device:R", "33", FP_R, {1: "X_D8", 2: "CVBS4"}, False, (5.0, 18.42, 180, "F"), ""),
    ("R6", "Device:R", "33", FP_R, {1: "X_D9", 2: "CVBS5"}, False, (5.0, 20.96, 180, "F"), ""),
    ("D1", "Device:D_Schottky", "B5819W", "Diode_SMD:D_SOD-123",
     {1: "+5V_XIAO", 2: "+5V_IN"}, False, (12.0, 32.2, 0, "F"), "Schottky 40V 1A SOD-123"),
    ("C1", "Device:C", "10uF", FP_C08, {1: "+5V_XIAO", 2: "GND"}, False, (8.0, 29.6, 90, "F"), "10V X5R"),
    ("C2", "Device:C", "100nF", FP_C06, {1: "+5V_XIAO", 2: "GND"}, False, (5.0, 31.12, 0, "F"), ""),
    ("C3", "Device:C", "100nF", FP_C06, {1: "+3V3_XIAO", 2: "GND"}, False, (5.0, 26.04, 0, "F"), ""),
    ("JP1", "Jumper:SolderJumper_2_Open", "3V3 from Pmod (open)",
     "Jumper:SolderJumper-2_P1.3mm_Open_RoundedPad1.0x1.5mm",
     {1: "+3V3_XIAO", 2: "PMOD_3V3"}, False, (5.4, 23.5, 0, "F"), "Close only when not using 5V input"),
    ("J2", "Connector_Generic:Conn_01x02", "5V IN (from Dock 5V pad)",
     "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
     {1: "+5V_IN", 2: "GND"}, False, (1.6, 10.8, 90, "F"), "wire pads"),
    ("TP1", "Connector:TestPoint", "OPT_CLK (XIAO GPIO2)",
     "TestPoint:TestPoint_THTPad_D1.5mm_Drill0.7mm",
     {1: "OPT_CLK"}, False, (7.3, 10.8, 0, "F"), "wire from XIAO back pad MTMS"),
    # Optional resistor DAC for analog CVBS out (C5VRX reference values), DNP.
    ("R10", "Device:R", "8.2k", FP_R, {1: "X_D4", 2: "VIDEO"}, True, (9.5, 16.5, 0, "B"), "DNP"),
    ("R11", "Device:R", "3.9k", FP_R, {1: "X_D5", 2: "VIDEO"}, True, (9.5, 18.3, 0, "B"), "DNP"),
    ("R12", "Device:R", "2.0k", FP_R, {1: "X_D6", 2: "VIDEO"}, True, (9.5, 20.1, 0, "B"), "DNP"),
    ("R13", "Device:R", "1.0k", FP_R, {1: "X_D7", 2: "VIDEO"}, True, (9.5, 21.9, 0, "B"), "DNP"),
    ("R14", "Device:R", "470", FP_R, {1: "X_D8", 2: "VIDEO"}, True, (9.5, 23.7, 0, "B"), "DNP"),
    ("R15", "Device:R", "240", FP_R, {1: "X_D9", 2: "VIDEO"}, True, (9.5, 25.5, 0, "B"), "DNP"),
    ("R16", "Device:R", "200", FP_R, {1: "VIDEO", 2: "GND"}, True, (9.5, 27.3, 0, "B"), "DNP"),
    ("C4", "Device:C", "470pF", FP_C06, {1: "VIDEO", 2: "GND"}, True, (9.5, 29.1, 0, "B"), "DNP"),
    ("J3", "Connector_Generic:Conn_01x02", "VIDEO OUT (optional)",
     "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
     {1: "VIDEO", 2: "GND"}, False, (14.96, 10.8, 90, "F"), "wire pads, DAC parts DNP"),
]

BOARD_W = 19.0
BOARD_H = 34.5
