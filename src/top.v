// Tang Primer 25K Dock: IQ logic analyser + 720x480p HDMI.
//   J6 (PMOD DVI): HDMI out, test pattern with per-pin IQ activity bars
//   J4: the 8 IQ inputs from the XIAO ESP32-C5 (see top.cst)
//   Debugger UART (COM4, 1 Mbaud): 'C' dumps raw 675 MS/s samples,
//   'S' the resampled ~80 MS/s symbols, 'B' symbols with the FM output
//   Top of the screen: waveform monitor of the demodulated video
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

    pll_135 u_pll (.clkin(clk), .clkout0(clk_5x), .clkout1(clk_iq_fast), .lock(pll_lock));

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
    wire [9:0] x, y;
    wire de, hsync, vsync, frame_start;
    video_timing u_timing (
        .clk(clk_pixel), .rst(rst), .x(x), .y(y), .de(de),
        .hsync(hsync), .vsync(vsync), .frame_start(frame_start)
    );

    wire [7:0] pr, pg, pb;
    test_pattern u_pattern (
        .clk(clk_pixel), .rst(rst), .x(x), .y(y), .frame_start(frame_start),
        .r(pr), .g(pg), .b(pb)
    );

    // Waveform monitor on the top 320 rows: one demodulated line per frame,
    // triggered on horizontal sync, 87.5 ns per pixel (63.0 us across).
    // y = 160 - vid / 8, so the scale is 25.6 px per MHz.
    wire signed [13:0] sc_rd;
    wire               sc_trig;
    scope_line u_scope (
        .clk_iq(clk_iq), .rst_iq(rst_iq), .in_valid(fm_valid), .vid(fm_vid),
        .clk_pixel(clk_pixel), .arm(frame_start), .rd_addr(x), .rd(sc_rd),
        .triggered(sc_trig)
    );

    reg  [9:0] x_d, y_d;
    reg  [9:0] ty_prev;
    wire signed [13:0] ty_s = 14'sd160 - (sc_rd >>> 3);
    wire [9:0] ty = (ty_s < 0) ? 10'd0 : (ty_s > 14'sd319) ? 10'd319 : ty_s[9:0];
    always @(posedge clk_pixel) begin
        x_d     <= x;
        y_d     <= y;
        ty_prev <= ty;
    end
    wire [9:0] t_lo = (ty < ty_prev) ? ty : ty_prev;
    wire [9:0] t_hi = (ty < ty_prev) ? ty_prev : ty;
    wire sc_area  = (y_d < 320) && (x_d < 720);
    wire sc_trace = (x_d > 0) && (y_d >= t_lo) && (y_d <= t_hi);
    wire sc_grid  = (y_d == 160) || (x_d == 114) || (x_d == 229) || (x_d == 343) ||
                    (x_d == 457) || (x_d == 571) || (x_d == 686);
    wire sc_led   = (x_d >= 700) && (x_d < 714) && (y_d >= 6) && (y_d < 20);
    reg  [23:0] sc_rgb;
    always @(*) begin
        if (sc_led)        sc_rgb = sc_trig ? 24'h20d040 : 24'hd03020;   // sync trigger seen
        else if (sc_trace) sc_rgb = 24'hf0f070;
        else if (sc_grid)  sc_rgb = 24'h303840;
        else               sc_rgb = 24'h0c1014;
    end

    // Bars over the ramp, row n at y = 332 + 14n, 11 px high:
    //   rows 0..7  IQ bit n, transitions per 12.4 ms / 1024
    //   rows 8, 9  resampler early / late votes per 0.78 ms / 128
    // Clipped at 700 px. The counts are written in the IQ domain and only
    // displayed, so they are read here without synchronisation.
    reg [3:0] row;
    reg       in_row;
    integer n;
    always @(*) begin
        row    = 4'd0;
        in_row = 1'b0;
        for (n = 0; n < 10; n = n + 1)
            if (y >= 332 + 14 * n && y < 343 + 14 * n) begin
                row    = n;
                in_row = 1'b1;
            end
    end
    reg [11:0] raw_len;
    always @(*) begin
        case (row)
            4'd8:    raw_len = {3'd0, early_cnt[15:7]};
            4'd9:    raw_len = {3'd0, late_cnt[15:7]};
            default: raw_len = activity[row[2:0] * 22 + 10 +: 12];
        endcase
    end
    wire [11:0] len = (raw_len > 12'd700) ? 12'd700 : raw_len;
    wire in_region = (y >= 328) && (y < 476) && (x > 0) && (x < 719);

    reg        ov_en;
    reg [23:0] ov_rgb;
    always @(posedge clk_pixel) begin
        ov_en <= in_region;
        if (in_row && x >= 10 && x < 10 + len)
            case (row)
                4'd3:    ov_rgb <= 24'hff8000;   // Q sign
                4'd7:    ov_rgb <= 24'h4080ff;   // I sign
                4'd8:    ov_rgb <= 24'he04060;   // early votes
                4'd9:    ov_rgb <= 24'h60c040;   // late votes
                default: ov_rgb <= row[2] ? 24'h00e0e0 : 24'he0e000;
            endcase
        else if (in_row && x < 10)
            ov_rgb <= row[3] ? 24'h404040 : row[2] ? 24'h006060 : 24'h606000;   // row marker
        else
            ov_rgb <= 24'h000000;
    end

    wire [7:0] r = sc_area ? sc_rgb[23:16] : ov_en ? ov_rgb[23:16] : pr;
    wire [7:0] g = sc_area ? sc_rgb[15:8]  : ov_en ? ov_rgb[15:8]  : pg;
    wire [7:0] b = sc_area ? sc_rgb[7:0]   : ov_en ? ov_rgb[7:0]   : pb;

    // The pattern and overlay have one clock of latency; delay the controls.
    reg de_d, hsync_d, vsync_d;
    always @(posedge clk_pixel) begin
        de_d    <= de;
        hsync_d <= hsync;
        vsync_d <= vsync;
    end

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
