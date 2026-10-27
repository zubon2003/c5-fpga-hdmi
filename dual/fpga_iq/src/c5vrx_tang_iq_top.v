// Top level for the Tang Primer 25K Dock, IQ version (FM demodulation in the FPGA).
//   J4 (right Pmod): XIAO-A IQ   J5 (middle Pmod): XIAO-B IQ   J6 (left Pmod): HDMI
//   USB-A D+ / D-: telemetry UART from XIAO-A / XIAO-B
//   J3 (2x20): Tang SDRAM module      S1: diversity / dual view
module c5vrx_tang_iq_top (
    input  wire        clk50,
    input  wire        s1,
    input  wire [7:0]  xa_iq,
    input  wire [7:0]  xb_iq,
    input  wire        xa_link,
    input  wire        xb_link,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

    output wire        O_sdram_clk,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [12:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [1:0]  O_sdram_dqm,
    inout  wire [15:0] IO_sdram_dq
);

    // ---------------- clocks and reset ----------------
    wire clk_5x, clk_os, clk, lock;
    gowin_pll u_pll (.clkin(clk50), .clkout0(clk_5x), .clkout1(clk_os), .lock(lock));

    CLKDIV u_div (.CLKOUT(clk), .HCLKIN(clk_5x), .RESETN(lock), .CALIB(1'b0));
    defparam u_div.DIV_MODE = "5";

    reg [15:0] por = 16'd0;
    reg        rst = 1'b1;
    always @(posedge clk or negedge lock) begin
        if (!lock) begin
            por <= 16'd0;
            rst <= 1'b1;
        end else if (por != 16'hffff) begin
            por <= por + 16'd1;
        end else
            rst <= 1'b0;
    end
    reg [1:0] rst_os_s = 2'b11;
    always @(posedge clk_os) rst_os_s <= {rst_os_s[0], rst};
    wire rst_os = rst_os_s[1];

    // ---------------- core ----------------
    wire [15:0] dq_o, dq_i;
    wire        dq_oe;
    wire [9:0]  t_r, t_g, t_b;

    c5vrx_core_iq u_core (
        .clk_os(clk_os), .rst_os(rst_os), .clk(clk), .rst(rst),
        .xa_iq(xa_iq), .xb_iq(xb_iq), .xa_link(xa_link), .xb_link(xb_link), .btn_mode(s1),
        .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n), .sd_cas_n(O_sdram_cas_n),
        .sd_we_n(O_sdram_wen_n), .sd_a(O_sdram_addr), .sd_ba(O_sdram_ba), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
        .tmds_r(t_r), .tmds_g(t_g), .tmds_b(t_b),
        .vid_r(), .vid_g(), .vid_b(), .vid_de(), .vid_hs(), .vid_vs(),
        .mode_dual(), .sel_ch(), .rx_valid(), .rx_overflow(),
        .iq_lock(), .link_ok(), .link_gain(), .link_flags());

    // SDRAM clock = inverted system clock
    ODDR u_sdclk (.Q0(O_sdram_clk), .Q1(), .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clk));

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_dq
            IOBUF u_dq (.O(dq_i[i]), .IO(IO_sdram_dq[i]), .I(dq_o[i]), .OEN(!dq_oe));
        end
    endgenerate

    // ---------------- HDMI (DVI) ----------------
    wire [9:0] t_c = 10'b0000011111;
    wire [3:0] ser;
    OSER10 u_ser0 (.Q(ser[0]), .D0(t_b[0]), .D1(t_b[1]), .D2(t_b[2]), .D3(t_b[3]), .D4(t_b[4]),
                   .D5(t_b[5]), .D6(t_b[6]), .D7(t_b[7]), .D8(t_b[8]), .D9(t_b[9]),
                   .PCLK(clk), .FCLK(clk_5x), .RESET(rst));
    OSER10 u_ser1 (.Q(ser[1]), .D0(t_g[0]), .D1(t_g[1]), .D2(t_g[2]), .D3(t_g[3]), .D4(t_g[4]),
                   .D5(t_g[5]), .D6(t_g[6]), .D7(t_g[7]), .D8(t_g[8]), .D9(t_g[9]),
                   .PCLK(clk), .FCLK(clk_5x), .RESET(rst));
    OSER10 u_ser2 (.Q(ser[2]), .D0(t_r[0]), .D1(t_r[1]), .D2(t_r[2]), .D3(t_r[3]), .D4(t_r[4]),
                   .D5(t_r[5]), .D6(t_r[6]), .D7(t_r[7]), .D8(t_r[8]), .D9(t_r[9]),
                   .PCLK(clk), .FCLK(clk_5x), .RESET(rst));
    OSER10 u_ser3 (.Q(ser[3]), .D0(t_c[0]), .D1(t_c[1]), .D2(t_c[2]), .D3(t_c[3]), .D4(t_c[4]),
                   .D5(t_c[5]), .D6(t_c[6]), .D7(t_c[7]), .D8(t_c[8]), .D9(t_c[9]),
                   .PCLK(clk), .FCLK(clk_5x), .RESET(rst));

    ELVDS_OBUF u_ob0 (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF u_ob1 (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF u_ob2 (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF u_obc (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule
