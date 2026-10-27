// Port-compatible empty stand-ins for the Gowin primitives used by the top
// level, so it can be linted / parsed without the vendor library.
module PLLA (output LOCK, output CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6,
    output CLKFBOUT, output [7:0] MDRDO, input CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input [2:0] PSSEL, input PSDIR, PSPULSE, SSCPOL, SSCON, input [6:0] SSCMDSEL,
    input [2:0] SSCMDSEL_FRAC, input MDCLK, input [1:0] MDOPC, input MDAINC, input [7:0] MDWDI);
    parameter FCLKIN = "50"; parameter IDIV_SEL = 1; parameter FBDIV_SEL = 1; parameter CLKFB_SEL = "INTERNAL";
    parameter ODIV0_SEL = 8; parameter ODIV0_FRAC_SEL = 0; parameter ODIV1_SEL = 8; parameter ODIV2_SEL = 8;
    parameter ODIV3_SEL = 8; parameter ODIV4_SEL = 8; parameter ODIV5_SEL = 8; parameter ODIV6_SEL = 8;
    parameter MDIV_SEL = 8; parameter MDIV_FRAC_SEL = 0;
    parameter CLKOUT0_EN = "TRUE"; parameter CLKOUT1_EN = "TRUE"; parameter CLKOUT2_EN = "TRUE"; parameter CLKOUT3_EN = "TRUE";
    parameter CLKOUT4_EN = "TRUE"; parameter CLKOUT5_EN = "TRUE"; parameter CLKOUT6_EN = "TRUE";
    parameter CLKOUT0_DT_DIR = 1; parameter CLKOUT1_DT_DIR = 1; parameter CLKOUT2_DT_DIR = 1; parameter CLKOUT3_DT_DIR = 1;
    parameter CLK0_IN_SEL = 0; parameter CLK0_OUT_SEL = 0; parameter CLK1_IN_SEL = 0; parameter CLK1_OUT_SEL = 0;
    parameter CLK2_IN_SEL = 0; parameter CLK2_OUT_SEL = 0; parameter CLK3_IN_SEL = 0; parameter CLK3_OUT_SEL = 0;
    parameter CLK4_IN_SEL = 0; parameter CLK4_OUT_SEL = 0; parameter CLK5_IN_SEL = 0; parameter CLK5_OUT_SEL = 0;
    parameter CLK6_IN_SEL = 0; parameter CLK6_OUT_SEL = 0;
    parameter CLKOUT0_PE_COARSE = 0; parameter CLKOUT0_PE_FINE = 0; parameter CLKOUT1_PE_COARSE = 0; parameter CLKOUT1_PE_FINE = 0;
    parameter CLKOUT2_PE_COARSE = 0; parameter CLKOUT2_PE_FINE = 0; parameter CLKOUT3_PE_COARSE = 0; parameter CLKOUT3_PE_FINE = 0;
    parameter CLKOUT4_PE_COARSE = 0; parameter CLKOUT4_PE_FINE = 0; parameter CLKOUT5_PE_COARSE = 0; parameter CLKOUT5_PE_FINE = 0;
    parameter CLKOUT6_PE_COARSE = 0; parameter CLKOUT6_PE_FINE = 0;
    parameter DE0_EN = "FALSE"; parameter DE1_EN = "FALSE"; parameter DE2_EN = "FALSE"; parameter DE3_EN = "FALSE";
    parameter DE4_EN = "FALSE"; parameter DE5_EN = "FALSE"; parameter DE6_EN = "FALSE"; parameter DYN_DPA_EN = "FALSE";
    parameter DYN_PE0_SEL = "FALSE"; parameter DYN_PE1_SEL = "FALSE"; parameter DYN_PE2_SEL = "FALSE"; parameter DYN_PE3_SEL = "FALSE";
    parameter DYN_PE4_SEL = "FALSE"; parameter DYN_PE5_SEL = "FALSE"; parameter DYN_PE6_SEL = "FALSE";
    parameter RESET_I_EN = "FALSE"; parameter RESET_O_EN = "FALSE"; parameter ICP_SEL = 6'b0; parameter LPF_RES = 3'b0;
    parameter LPF_CAP = 2'b0; parameter SSC_EN = "FALSE";
    parameter CLKOUT0_DT_STEP = 0; parameter CLKOUT1_DT_STEP = 0; parameter CLKOUT2_DT_STEP = 0; parameter CLKOUT3_DT_STEP = 0;
endmodule
module CLKDIV (output CLKOUT, input HCLKIN, RESETN, CALIB); parameter DIV_MODE = "2"; endmodule
module ODDR (output Q0, Q1, input D0, D1, TX, CLK); endmodule
module IOBUF (output O, inout IO, input I, OEN); endmodule
module OSER10 (output Q, input D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, PCLK, FCLK, RESET); endmodule
module ELVDS_OBUF (input I, output O, OB); endmodule
