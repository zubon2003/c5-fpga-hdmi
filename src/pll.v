// 50 MHz board clock -> VCO = 50 / IDIV 1 * MDIV 27 = 1350 MHz
// (PFD must stay within 19..87.5 MHz).
//   CLKOUT0 = 1350 / 3.625 = 372.41 MHz: TMDS fast clock (5 x 74.48 MHz
//             pixel clock for 720p, +0.31 % against 74.25; OSER10 is DDR,
//             so it carries 744.8 Mbit/s per lane)
//   CLKOUT1 = 1350 / 4 = 337.5 MHz: IQ input IDES8 fast clock (675 MS/s)
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
    defparam pll.ODIV0_SEL = 3;
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
