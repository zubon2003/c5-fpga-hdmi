// One DVI/HDMI port: three TMDS data lanes plus the TMDS clock lane, each
// serialised 10:1 by OSER10 and driven by an emulated LVDS pair.
// No HDMI data islands are sent (DVI mode, RGB full range).
module dvi_tx (
    input  wire       clk_pixel,
    input  wire       clk_5x,
    input  wire       rst,
    input  wire [9:0] sym0,   // blue
    input  wire [9:0] sym1,   // green
    input  wire [9:0] sym2,   // red
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    wire [39:0] sym = {10'b0000011111, sym2, sym1, sym0};
    wire [3:0]  ser, pad_p, pad_n;

    assign tmds_d_p   = pad_p[2:0];
    assign tmds_d_n   = pad_n[2:0];
    assign tmds_clk_p = pad_p[3];
    assign tmds_clk_n = pad_n[3];

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_lane
            OSER10 oser (
                .Q(ser[k]),
                .D0(sym[k*10+0]), .D1(sym[k*10+1]), .D2(sym[k*10+2]),
                .D3(sym[k*10+3]), .D4(sym[k*10+4]), .D5(sym[k*10+5]),
                .D6(sym[k*10+6]), .D7(sym[k*10+7]), .D8(sym[k*10+8]),
                .D9(sym[k*10+9]),
                .PCLK(clk_pixel),
                .FCLK(clk_5x),
                .RESET(rst)
            );
            ELVDS_OBUF obuf (.I(ser[k]), .O(pad_p[k]), .OB(pad_n[k]));
        end
    endgenerate
endmodule
