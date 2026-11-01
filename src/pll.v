// Two PLLs from the 50 MHz board clock (PFD must stay within 19..87.5 MHz,
// VCO within 700..1400 MHz).
//
// pll: VCO = 50 / IDIV 1 * MDIV 27 = 1350 MHz
//   CLKOUT0 = 1350 / 20.625 = 65.4545 MHz: reference for pll_hdmi
//   CLKOUT1 = 1350 / 4 = 337.5 MHz: IQ input IDES8 fast clock (675 MS/s)
//
// pll_hdmi: VCO = 65.4545 / IDIV 1 * MDIV 17 = 1112.73 MHz
//   CLKOUT0 = 1112.73 / 3 = 370.91 MHz: TMDS fast clock (5 x 74.1818 MHz
//             pixel clock, 81 ppm above CEA's 74.25 / 1.001 = 74.1758, so
//             1650 x 750 frames at 59.945 Hz; OSER10 is DDR, so 742 Mbit/s
//             per lane). HDZero goggles from
//             9.6.0-rc1 show black for the earlier non-standard 1631 x 750
//             at 73.33 MHz. A fractional MDIV (50 * 22.25 / 3) gave no
//             picture at all, hence the two PLLs in a row.
//   CLKOUT0 takes dynamic phase steps (psdir / pspulse, 1/8 VCO period =
//   112.3 ps each, UG306 "Phase Shift") so the output follows the input
//   field rate without changing the HDMI timing (video_timing.v, pclk).
//   ODIV0 must be an integer: the phase wraps after ODIV0 VCO periods, so
//   with the old 3.625 divider the steps only went round a 3-period circle
//   and did not move the frequency.
// Parameter set follows the Gowin IP generator output in Sipeed's
// TangPrimer-25K-example hdmi project; only the dividers differ.
module pll (
    input  wire clkin,
    output wire clkout0,
    output wire clkout1,
    output wire lock
);
    wire gnd = 1'b0;

    PLLA pll (
        .LOCK(lock),
        .CLKOUT0(clkout0),
        .CLKOUT1(clkout1), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(),
        .MDRDO(),
        .CLKIN(clkin),
        .CLKFB(gnd),
        .RESET(gnd),
        .PLLPWD(gnd),
        .RESET_I(gnd),
        .RESET_O(gnd),
        .PSSEL(3'b000),
        .PSDIR(gnd),
        .PSPULSE(gnd),
        .SSCPOL(gnd),
        .SSCON(gnd),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b000),
        .MDCLK(gnd),
        .MDOPC(2'b00),
        .MDAINC(gnd),
        .MDWDI(8'b0)
    );

    defparam pll.FCLKIN = "50";
    defparam pll.IDIV_SEL = 1;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.CLKFB_SEL = "INTERNAL";
    defparam pll.MDIV_SEL = 27;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_SEL = 20;
    defparam pll.ODIV0_FRAC_SEL = 5;     // + 5/8
    defparam pll.ODIV1_SEL = 4;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "TRUE";
    defparam pll.CLKOUT2_EN = "FALSE";
    defparam pll.CLKOUT3_EN = "FALSE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKOUT0_DT_DIR = 1'b1;
    defparam pll.CLKOUT1_DT_DIR = 1'b1;
    defparam pll.CLK0_IN_SEL = 1'b0;
    defparam pll.CLK0_OUT_SEL = 1'b0;
    defparam pll.CLK1_IN_SEL = 1'b0;
    defparam pll.CLK1_OUT_SEL = 1'b0;
    defparam pll.CLKOUT0_PE_COARSE = 0;
    defparam pll.CLKOUT0_PE_FINE = 0;
    defparam pll.CLKOUT1_PE_COARSE = 0;
    defparam pll.CLKOUT1_PE_FINE = 0;
    defparam pll.DE0_EN = "FALSE";
    defparam pll.DE1_EN = "FALSE";
    defparam pll.DYN_DPA_EN = "FALSE";
    defparam pll.DYN_PE0_SEL = "FALSE";
    defparam pll.DYN_PE1_SEL = "FALSE";
    defparam pll.RESET_I_EN = "FALSE";
    defparam pll.RESET_O_EN = "FALSE";
    defparam pll.ICP_SEL = 6'bXXXXXX;
    defparam pll.LPF_RES = 3'bXXX;
    defparam pll.LPF_CAP = 2'b00;
    defparam pll.SSC_EN = "FALSE";
endmodule

module pll_hdmi (
    input  wire clkin,
    output wire clkout0,
    input  wire psdir,
    input  wire pspulse,
    output wire lock
);
    wire gnd = 1'b0;

    PLLA pll (
        .LOCK(lock),
        .CLKOUT0(clkout0),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(),
        .MDRDO(),
        .CLKIN(clkin),
        .CLKFB(gnd),
        .RESET(gnd),
        .PLLPWD(gnd),
        .RESET_I(gnd),
        .RESET_O(gnd),
        .PSSEL(3'b000),
        .PSDIR(psdir),
        .PSPULSE(pspulse),
        .SSCPOL(gnd),
        .SSCON(gnd),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b000),
        .MDCLK(gnd),
        .MDOPC(2'b00),
        .MDAINC(gnd),
        .MDWDI(8'b0)
    );

    defparam pll.FCLKIN = "65.455";
    defparam pll.IDIV_SEL = 1;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.CLKFB_SEL = "INTERNAL";
    defparam pll.MDIV_SEL = 17;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_SEL = 3;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.ODIV1_SEL = 8;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "FALSE";
    defparam pll.CLKOUT2_EN = "FALSE";
    defparam pll.CLKOUT3_EN = "FALSE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKOUT0_DT_DIR = 1'b1;
    defparam pll.CLK0_IN_SEL = 1'b0;
    defparam pll.CLK0_OUT_SEL = 1'b0;
    defparam pll.CLKOUT0_PE_COARSE = 0;
    defparam pll.CLKOUT0_PE_FINE = 0;
    defparam pll.DE0_EN = "FALSE";
    defparam pll.DYN_DPA_EN = "TRUE";
    defparam pll.DYN_PE0_SEL = "TRUE";
    defparam pll.RESET_I_EN = "FALSE";
    defparam pll.RESET_O_EN = "FALSE";
    defparam pll.ICP_SEL = 6'bXXXXXX;
    defparam pll.LPF_RES = 3'bXXX;
    defparam pll.LPF_CAP = 2'b00;
    defparam pll.SSC_EN = "FALSE";
endmodule
