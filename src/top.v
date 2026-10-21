// Tang Primer 25K Dock: C5 IQ -> FM demodulator, 1280x720p HDMI.
//   J6 (PMOD DVI): HDMI out, waveform monitor and per-pin IQ activity bars
//   J4: the 8 IQ inputs from the XIAO ESP32-C5 (see top.cst)
//   Debugger UART (COM4, 1 Mbaud): 'C' dumps raw 675 MS/s samples,
//   'S' the resampled ~80 MS/s symbols, 'B' symbols with the FM output
module top (
    input  wire       clk,          // 50 MHz
    output wire       led,
    input  wire [7:0] iq,           // PARLIO data-bit order: Q bits 0..3, I bits 4..7
    input  wire       uart_rx,
    output wire       uart_tx,

    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p,   tmds_d_n
);
    wire clk_5x, clk_iq_fast, pll_lock, clk_pixel, clk_iq;

    pll u_pll (.clkin(clk), .clkout0(clk_5x), .clkout1(clk_iq_fast), .lock(pll_lock));

    // IQ domain: IDES8 at 337.5 MHz DDR, 8 samples per 84.375 MHz clock.
    CLKDIV u_div_iq (.CLKOUT(clk_iq), .HCLKIN(clk_iq_fast), .RESETN(pll_lock), .CALIB(1'b0));
    defparam u_div_iq.DIV_MODE = "4";

    CLKDIV u_div (.CLKOUT(clk_pixel), .HCLKIN(clk_5x), .RESETN(pll_lock), .CALIB(1'b0));
    defparam u_div.DIV_MODE = "5";

    // Hold reset for 16 pixel clocks after the PLL locks.
    reg [3:0] rst_cnt = 4'd0;
    always @(posedge clk_pixel or negedge pll_lock) begin
        if (!pll_lock)            rst_cnt <= 4'd0;
        else if (rst_cnt != 4'hf) rst_cnt <= rst_cnt + 4'd1;
    end
    wire rst = (rst_cnt != 4'hf);

    reg [1:0] rst_iq_sync = 2'b11;
    always @(posedge clk_iq) rst_iq_sync <= {rst_iq_sync[0], rst};
    wire rst_iq = rst_iq_sync[1];

    // ---- IQ capture: 675 MS/s, 8 samples per clock ----
    wire [7:0] q [0:7];          // q[pin][j], j = 0 oldest
    wire [63:0] win;
    genvar k, j;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_ides
            IDES8 ides (.D(iq[k]), .FCLK(clk_iq_fast), .PCLK(clk_iq), .CALIB(1'b0), .RESET(rst_iq),
                        .Q0(q[k][0]), .Q1(q[k][1]), .Q2(q[k][2]), .Q3(q[k][3]),
                        .Q4(q[k][4]), .Q5(q[k][5]), .Q6(q[k][6]), .Q7(q[k][7]));
            for (j = 0; j < 8; j = j + 1) begin : g_bit
                assign win[j*8 + k] = q[k][j];
            end
        end
    endgenerate

    wire        sym_valid;
    wire [7:0]  sym;
    wire [15:0] early_cnt, late_cnt;
    iq_resampler u_rs (
        .clk(clk_iq), .rst(rst_iq), .win(win),
        .sym_valid(sym_valid), .sym(sym), .early_cnt(early_cnt), .late_cnt(late_cnt)
    );

    wire               fm_valid;
    wire signed [13:0] fm_vid;
    wire [7:0]         fm_sym;
    fm_demod u_fm (
        .clk(clk_iq), .rst(rst_iq), .in_valid(sym_valid), .sym(sym),
        .out_valid(fm_valid), .vid(fm_vid), .sym_out(fm_sym)
    );

    wire       rx_valid, tx_valid, tx_ready, la_busy;
    wire [7:0] rx_data, tx_data;
    wire [175:0] activity;

    uart_rx #(.DIV(84)) u_rx (.clk(clk_iq), .rst(rst_iq), .rxd(uart_rx),
                              .valid(rx_valid), .data(rx_data));
    uart_tx #(.DIV(84)) u_tx (.clk(clk_iq), .rst(rst_iq), .valid(tx_valid),
                              .data(tx_data), .ready(tx_ready), .txd(uart_tx));

    iq_la u_la (
        .clk(clk_iq), .rst(rst_iq), .win(win), .sym_valid(sym_valid), .sym(sym),
        .fm_valid(fm_valid), .fm_vid(fm_vid), .fm_sym(fm_sym),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .busy(la_busy), .activity(activity)
    );

    // ---- Video ----
    wire [10:0] x;
    wire [9:0]  y;
    wire de, hsync, vsync, frame_start, line_start;
    video_timing u_timing (
        .clk(clk_pixel), .rst(rst), .x(x), .y(y), .de(de),
        .hsync(hsync), .vsync(vsync), .frame_start(frame_start), .line_start(line_start)
    );

    wire signed [13:0] sc_rd;
    wire               sc_trig;
    scope_line u_scope (
        .clk_iq(clk_iq), .rst_iq(rst_iq), .in_valid(fm_valid), .vid(fm_vid),
        .clk_pixel(clk_pixel), .arm(frame_start), .rd_addr(x), .rd(sc_rd),
        .triggered(sc_trig)
    );

    wire [23:0] rgb;
    wire        de_d, hsync_d, vsync_d;
    display u_display (
        .clk(clk_pixel), .x(x), .y(y), .de(de), .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .activity(activity), .early_cnt(early_cnt),
        .late_cnt(late_cnt), .sc_rd(sc_rd), .sc_trig(sc_trig),
        .rgb(rgb), .de_o(de_d), .hsync_o(hsync_d), .vsync_o(vsync_d)
    );
    wire [7:0] r = rgb[23:16], g = rgb[15:8], b = rgb[7:0];

    wire [9:0] sym_b, sym_g, sym_r;
    tmds_encoder u_enc_b (.clk(clk_pixel), .rst(rst), .de(de_d), .ctrl({vsync_d, hsync_d}), .din(b), .dout(sym_b));
    tmds_encoder u_enc_g (.clk(clk_pixel), .rst(rst), .de(de_d), .ctrl(2'b00),            .din(g), .dout(sym_g));
    tmds_encoder u_enc_r (.clk(clk_pixel), .rst(rst), .de(de_d), .ctrl(2'b00),            .din(r), .dout(sym_r));

    dvi_tx u_dvi (.clk_pixel(clk_pixel), .clk_5x(clk_5x), .rst(rst),
        .sym0(sym_b), .sym1(sym_g), .sym2(sym_r),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // Heartbeat ~1.6 Hz while the PLL is locked; solid on during a capture.
    reg [23:0] blink = 24'd0;
    always @(posedge clk_pixel) blink <= blink + 24'd1;
    assign led = pll_lock & (blink[23] | la_busy);
endmodule
