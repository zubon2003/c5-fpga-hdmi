// Tang Primer 25K Dock: C5 IQ -> FM demodulator, 1280x720p HDMI.
//   J5 (PMOD DVI, middle PMOD): HDMI out, waveform monitor and per-pin IQ activity bars
//   J4: the 8 IQ inputs from the XIAO ESP32-C5 (see top.cst)
//   Debugger UART (COM4, 1 Mbaud): 'C' dumps raw 675 MS/s samples,
//   'S' the resampled ~80 MS/s symbols, 'B' symbols with the FM output,
//   'T' the sync separator status,
//   'P' picture display, 'W' waveform monitor display,
//   'u' / 'd' first active line -/+ 1, 'h' / 'l' picture start -/+ 16 samples
//   (0.2 us), 'f' field offset direction, 'c' colour on/off, 'v' V sign,
//   'a' / 'z' colour saturation +/- 0.25x, '[' / ']' hue -/+ 11.25 degrees,
//   'm' FM demodulator mode 0..3 (src/fm_demod.v; 1 at power-up),
//   'A' picture 4:3 (960 x 720 with black pillars, power-up) / 16:9 stretch,
//   'g' output genlock: off (power-up; the SDRAM field store decouples the
//   output) / porch lines / pixel clock (PLL phase steps),
//   'K' SDRAM read timing test, 'k' invert the SDRAM clock and test,
//   'R' read back the settings above (8 bytes, see `settings` below)
//   (sdram_fb.v; result in status word 13)
module top (
    input  wire       clk,          // 50 MHz
    input  wire [7:0] iq,           // PARLIO data-bit order: Q bits 0..3, I bits 4..7
    input  wire       uart_rx,
    output wire       uart_tx,
    input  wire [1:0] btn,          // Dock keys: [0] H11 band, [1] H10 channel (c5_link.v)
    input  wire       link_rx,      // USB-A J13 D- (K6) <- XIAO D4 (C5 GPIO23, UART build)
    output wire       link_tx,      // USB-A J13 D+ (L6) -> XIAO D5 (C5 GPIO24)

    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p,   tmds_d_n,

    // Tang SDRAM module on the Dock 40-pin header
    output wire        O_sdram_clk,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [1:0]  O_sdram_ba,
    output wire [12:0] O_sdram_addr,
    output wire [1:0]  O_sdram_dqm,
    inout  wire [15:0] IO_sdram_dq
);
    wire clk_5x, clk_iq_fast, pll_lock, clk_pixel, clk_iq;
    wire lock_iq, lock_hdmi;
    assign pll_lock = lock_iq & lock_hdmi;

    wire ps_dir, ps_pulse;
    wire clk_ref;
    pll u_pll (.clkin(clk), .clkout0(clk_ref), .clkout1(clk_iq_fast), .lock(lock_iq));
    pll_hdmi u_pll_hdmi (.clkin(clk_ref), .clkout0(clk_5x),
                         .psdir(ps_dir), .pspulse(ps_pulse), .lock(lock_hdmi));

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

    reg  [1:0]         fm_mode = 2'd1;      // PLL fast; set from the UART below
    wire               fm_valid;
    wire signed [13:0] fm_vid;
    wire [7:0]         fm_sym;
    wire signed [9:0]  fm_d;
    fm_demod u_fm (
        .clk(clk_iq), .rst(rst_iq), .in_valid(sym_valid), .sym(sym), .mode(fm_mode),
        .out_valid(fm_valid), .vid(fm_vid), .sym_out(fm_sym), .d_out(fm_d)
    );

    wire [255:0] vin_status;   // from video_in below
    // Receiver link (button, channel reports); its channel replaces status
    // word 1 (n) and its MHz word 6 (thr) for the UART 'T' packet.
    wire [15:0]  ch_name, ch_mhz;
    wire [7:0]   ch_reports, link_edges, link_bytes;
    c5_link u_link (.clk(clk_iq), .rst(rst_iq), .btn(btn), .rxd(link_rx), .txd(link_tx),
                    .ch_name(ch_name), .ch_mhz(ch_mhz), .reports(ch_reports),
                    .rx_edges(link_edges), .rx_bytes(link_bytes));
    // Pixel clock meter: pixel clocks per 2^20 IQ clocks (12.43 ms), low 16
    // bits (about 921,894 at 74.1818 MHz), with lock_hdmi as bit 15 of word 14's
    // place... word 15 (was the link's RX bytes | edges).
    reg  [23:0] pm_cnt = 24'd0;                       // pixel domain, Gray coded out
    reg  [23:0] pm_gray = 24'd0;
    always @(posedge clk_pixel) begin
        pm_cnt  <= pm_cnt + 24'd1;
        pm_gray <= (pm_cnt >> 1) ^ pm_cnt;
    end
    reg  [23:0] pm_g1, pm_g2;
    reg  [19:0] pm_win = 20'd0;
    reg  [23:0] pm_last;
    reg  [15:0] pm_out = 16'd0;
    integer gi;
    reg  [23:0] pm_bin;
    always @(*) begin
        pm_bin[23] = pm_g2[23];
        for (gi = 22; gi >= 0; gi = gi - 1) pm_bin[gi] = pm_bin[gi + 1] ^ pm_g2[gi];
    end
    always @(posedge clk_iq) begin
        pm_g1  <= pm_gray;
        pm_g2  <= pm_g1;
        pm_win <= pm_win + 20'd1;
        if (&pm_win) begin
            pm_out  <= pm_bin[15:0] - pm_last[15:0];
            pm_last <= pm_bin;
        end
    end
    wire [15:0]  fb_status;    // from sdram_fb below, replaces word 13
    wire [255:0] la_status = {pm_out, vin_status[239:224], fb_status, vin_status[207:112], ch_mhz,
                              vin_status[95:32], ch_name, vin_status[15:0]};
    wire [15:0]  out_jumps;    // from video_timing below
    wire         cdbg_v;
    wire [31:0]  cdbg_w;
    wire       rx_valid, tx_valid, tx_ready, la_busy;
    wire [7:0] rx_data, tx_data;
    wire [175:0] activity;

    uart_rx #(.DIV(84)) u_rx (.clk(clk_iq), .rst(rst_iq), .rxd(uart_rx),
                              .valid(rx_valid), .data(rx_data));
    uart_tx #(.DIV(84)) u_tx (.clk(clk_iq), .rst(rst_iq), .valid(tx_valid),
                              .data(tx_data), .ready(tx_ready), .txd(uart_tx));

    wire [63:0] settings;      // UART settings for 'R', assigned below
    iq_la u_la (
        .clk(clk_iq), .rst(rst_iq), .win(win), .sym_valid(sym_valid), .sym(sym),
        .fm_valid(fm_valid), .fm_vid(fm_vid), .fm_sym(fm_sym), .status(la_status), .settings(settings),
        .g_valid(cdbg_v), .g_word(cdbg_w),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .busy(la_busy), .activity(activity)
    );

    // ---- NTSC sync separation and line sampling (IQ domain) ----
    // Runtime settings from the UART (IQ domain).
    reg        pic_mode_iq = 1'b1;
    reg [9:0]  first_line  = 10'd16;
    reg [12:0] act_start   = 13'd752;
    reg        par_inv     = 1'b1;     // measured: OSD edge moves 1 line between fields, 2 with 0
    reg        color_on    = 1'b1;
    reg        v_inv       = 1'b1;     // natural hues on the board (skin, yellow box)
    reg [3:0]  sat         = 4'd4;     // 1x
    reg [4:0]  hue         = 5'd0;
    reg        ar43        = 1'b1;
    reg [1:0]  gl_mode     = 2'd1;     // 0 pixel clock, 1 off, 2 porch lines
    wire       bypass      = (gl_mode != 2'd1);   // genlock on: no SDRAM (below)
    // Settings read back with 'R' (iq_la.v): byte 0 {v_inv, color_on,
    // fm_mode, gl_mode, ar43, picture}, 1 {par_inv, sat}, 2 hue, 3 first
    // line, 4..5 picture start (act), 6 layout version (1), 7 zero.
    assign settings = {8'd0, 8'd1, 3'd0, act_start, first_line[7:0], 3'd0, hue,
                       3'd0, par_inv, sat, v_inv, color_on, fm_mode, gl_mode, ar43, pic_mode_iq};
    reg        fb_recal    = 1'b0;
    reg        fb_flip     = 1'b0;
    always @(posedge clk_iq) begin
        fb_recal <= rx_valid && rx_data == "K";
        fb_flip  <= rx_valid && rx_data == "k";
    end
    always @(posedge clk_iq) if (rx_valid) begin
        case (rx_data)
            "P": pic_mode_iq <= 1'b1;
            "W": pic_mode_iq <= 1'b0;
            "u": if (first_line != 0)       first_line <= first_line - 10'd1;
            "d": if (first_line != 10'd60)  first_line <= first_line + 10'd1;
            "h": if (act_start > 13'd600)   act_start  <= act_start - 13'd16;
            "l": if (act_start < 13'd1100)  act_start  <= act_start + 13'd16;
            "f": par_inv  <= ~par_inv;
            "c": color_on <= ~color_on;
            "v": v_inv    <= ~v_inv;
            "a": if (sat != 4'd15) sat <= sat + 4'd1;
            "z": if (sat != 4'd0)  sat <= sat - 4'd1;
            "[": hue <= hue - 5'd1;
            "]": hue <= hue + 5'd1;
            "m": fm_mode <= fm_mode + 2'd1;
            "A": ar43    <= ~ar43;
            "g": gl_mode <= (gl_mode == 2'd2) ? 2'd0 : gl_mode + 2'd1;
            default: ;
        endcase
    end

    wire        lb_we;
    wire [14:0] lb_waddr, lb_waddr24;
    wire [15:0] lb_wdata;
    wire        field_tg, field_parity, field_real;
    wire        ln_done;
    wire [7:0]  ln_idx;
    wire        fb_parity;     // parity of the field shown (sdram_fb)
    wire [15:0] real_lines, field_lines;
    video_in u_vin (
        .clk(clk_iq), .rst(rst_iq), .in_valid(fm_valid), .vid(fm_vid), .d(fm_d),
        .first(first_line), .act(act_start), .ar43(ar43),
        .we(lb_we), .waddr(lb_waddr), .waddr24(lb_waddr24), .wdata(lb_wdata),
        .field_tg(field_tg), .ln_done(ln_done), .ln_idx(ln_idx),
        .parity(field_parity), .field_real(field_real),
        .real_lines(real_lines), .field_lines(field_lines), .status(vin_status), .jumps(out_jumps),
        .cdbg_v(cdbg_v), .cdbg_w(cdbg_w)
    );

    // To the pixel domain: field start (edge of the toggle), quasi-static
    // settings through two flip-flops. field_real is set at the field start,
    // ~18 lines before the toggle, so it is stable when the edge arrives.
    // Only real fields lock the output: a synthesised field (no vertical
    // sync, e.g. signal lost) used to re-acquire the output several times a
    // second, and the HDMI monitor / capture card lost the picture each time
    // (blackouts in flight, 2026-10-22).
    reg [2:0] field_s;
    reg [1:0] freal_s;
    reg [1:0] parity_s, mode_s, color_s, vinv_s, ar43_s, pclk_s, free_s, byp_s;
    reg [3:0] sat_s1, sat_s2;
    reg [4:0] hue_s1, hue_s2;
    always @(posedge clk_pixel) begin
        field_s  <= {field_s[1:0], field_tg};
        freal_s  <= {freal_s[0], field_real};
        parity_s <= {parity_s[0], (bypass ? field_parity : fb_parity) ^ par_inv};
        mode_s   <= {mode_s[0], pic_mode_iq};
        color_s  <= {color_s[0], color_on};
        vinv_s   <= {vinv_s[0], v_inv};
        ar43_s   <= {ar43_s[0], ar43};
        pclk_s   <= {pclk_s[0], gl_mode == 2'd0};
        byp_s    <= {byp_s[0], bypass};
        free_s   <= {free_s[0], gl_mode == 2'd1};
        sat_s1   <= sat;
        sat_s2   <= sat_s1;
        hue_s1   <= hue;
        hue_s2   <= hue_s1;
    end
    wire field_go = (field_s[2] ^ field_s[1]) && freal_s[1];

    // ---- Video ----
    wire [10:0] x;
    wire [9:0]  y;
    wire de, hsync, vsync, frame_start, line_start;
    video_timing u_timing (
        .clk(clk_pixel), .rst(rst), .go(field_go), .pclk(pclk_s[1]), .free(free_s[1]),
        .ps_pulse(ps_pulse), .ps_dir(ps_dir), .x(x), .y(y), .de(de),
        .hsync(hsync), .vsync(vsync), .frame_start(frame_start), .line_start(line_start),
        .jumps(out_jumps)
    );

    wire signed [13:0] sc_rd;
    wire               sc_trig;
    scope_line u_scope (
        .clk_iq(clk_iq), .rst_iq(rst_iq), .in_valid(fm_valid), .vid(fm_vid),
        .clk_pixel(clk_pixel), .arm(frame_start), .rd_addr(x), .rd(sc_rd),
        .triggered(sc_trig)
    );

    // ---- SDRAM field store ----
    // Input ring (video_in) -> SDRAM -> output ring (display). Once per
    // output line the pixel domain asks for the field lines the display
    // needs next: lines 0..4 on the last line of a frame, then one more
    // every 3 lines (a field line covers 3 output lines), up to 239. The
    // field store uses 8 lines of the output ring; at most ~6 are in use.
    //
    // SDRAM bypass: with genlock on (g: porch lines or pixel clock) the
    // output follows the input, so video_in writes the output ring directly
    // as a 24-line ring (line mod 24; the output trails the input by up to
    // ~14 lines plus 2 of look-ahead) and the display reads it as before the
    // field store (latency ~0.2 ms at the top of the picture to ~1 ms at the
    // bottom). This works without the SDRAM module; sdram_fb keeps running
    // but its output ring writes are ignored.
    wire [12:0] ir_addr;
    wire [15:0] ir_data;
    line_buffer u_iring (
        .wclk(clk_iq), .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
        .rclk(clk_iq), .raddr({2'b00, ir_addr}), .rdata(ir_data)
    );
    reg        rq_tg = 1'b0, rq_frame = 1'b0;
    reg [7:0]  rq_line = 8'd0;
    reg [1:0]  rq_m3 = 2'd0;
    always @(posedge clk_pixel) if (line_start) begin
        rq_tg <= ~rq_tg;
        if (y == 10'd749) begin
            rq_frame <= 1'b1;
            rq_line  <= 8'd4;
            rq_m3    <= 2'd0;
        end else begin
            rq_frame <= 1'b0;
            rq_m3    <= (rq_m3 == 2'd2) ? 2'd0 : rq_m3 + 2'd1;
            if (rq_m3 == 2'd2 && rq_line != 8'd239) rq_line <= rq_line + 8'd1;
        end
    end
    wire        or_we;
    wire [12:0] or_addr;
    wire [15:0] or_data;
    sdram_fb u_fb (
        .clk(clk_iq), .rst(rst_iq),
        .sd_clk(O_sdram_clk), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba),
        .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm), .sd_dq(IO_sdram_dq),
        .ln_done(ln_done), .ln_idx(ln_idx), .parity(field_parity),
        .ir_addr(ir_addr), .ir_data(ir_data),
        .or_we(or_we), .or_addr(or_addr), .or_data(or_data),
        .req_tg(rq_tg), .req_frame(rq_frame), .req_line(rq_line), .rd_parity(fb_parity),
        .recal(fb_recal), .flip_ck(fb_flip), .status(fb_status)
    );

    wire [14:0] pic_addr;
    wire [15:0] pic;
    line_buffer #(.LINES(24)) u_oring (
        .wclk(clk_iq),
        .we(bypass ? lb_we : or_we),
        .waddr(bypass ? lb_waddr24 : {2'b00, or_addr}),
        .wdata(bypass ? lb_wdata : or_data),
        .rclk(clk_pixel), .raddr(pic_addr), .rdata(pic)
    );

    wire [23:0] rgb;
    wire        de_d, hsync_d, vsync_d;
    display u_display (
        .clk(clk_pixel), .x(x), .y(y), .de(de), .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .activity(activity), .early_cnt(early_cnt),
        .late_cnt(late_cnt), .sc_rd(sc_rd), .sc_trig(sc_trig),
        .pic_mode(mode_s[1]), .ar43(ar43_s[1]), .parity(parity_s[1]), .bypass(byp_s[1]), .color_on(color_s[1]), .v_inv(vinv_s[1]), .sat(sat_s2), .hue(hue_s2),
        .osd_name(ch_name),
        .pic_addr(pic_addr), .pic(pic),
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
endmodule
