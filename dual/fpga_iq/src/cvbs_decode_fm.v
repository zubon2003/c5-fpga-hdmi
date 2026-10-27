// CVBS decoder for one channel fed by the FPGA FM discriminator (monochrome).
//
// Derived from the v1 cvbs_decode (6-bit C5VRX DAC levels).  Differences:
//
//  - Input is the raw 20 MS/s frequency from fm_demod (signed, 4.883 kHz/LSB)
//    instead of DAC codes.  A level stage maps it to 8-bit video codes
//    (sync tip 0, blanking 80, white ~240, i.e. 4x the v1 levels):
//        v = 80 + ((f - off) * scale) >> 12
//    off follows the back-porch (blanking) frequency and scale makes the
//    sync depth (blanking - tip) 80 codes, both measured on every line with
//    a valid H-sync.  So the VTX deviation and a carrier offset are
//    calibrated out per line.  The defaults (blanking -1.0 MHz, 4 MHz sync
//    depth: C5VRX-5's AFC target and its board-measured carrier) are
//    restored when no vertical sync has been seen for ~100 ms.
//  - Thresholds and arithmetic are widened to 8 bits.
//  - Quality also counts FM clicks (phase steps through the origin cells)
//    on the stored lines, which tracks C/N directly; the receiver-reported
//    "no carrier" flag (link_rx) forces the worst quality.
//
// Everything else (sync separator, flywheel, field / standard detection,
// box-5 luma filter, back-porch clamp, 640-pixel resampler) is unchanged.
module cvbs_decode_fm (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire signed [12:0] f_in,
    input  wire [1:0]  click,
    input  wire        no_carrier,    // from the XIAO telemetry, 0 if unknown

    output reg         pix_we,
    output reg  [9:0]  pix_x,
    output reg  [7:0]  pix_y,
    output reg         pix_slot,      // line-buffer slot (= field line bit 0)

    output reg         line_done,     // pulse: field line line_idx is complete
    output reg  [8:0]  line_idx,
    output reg         field_start,   // pulse: vertical interval detected
    output reg         field_end,     // pulse: last active line was completed
    output reg         field_par,     // 0: broad pulses aligned to line start
    output reg         std_pal,       // 0: NTSC 525/60, 1: PAL 625/50
    output reg  [15:0] quality,
    output reg  signed [12:0] lvl_off,   // diagnostics: blanking frequency
    output reg  [11:0] lvl_scale         //              video codes per LSB, Q12
);

    localparam signed [12:0] OFF0    = -13'sd205;   // -1.0 MHz
    localparam        [11:0] SCALE0  = 12'd400;     // 80 codes per 4.0 MHz
    localparam        [7:0]  SYNC_TH = 8'd40;

    wire [10:0] LINE_LEN = std_pal ? 11'd1280 : 11'd1271;
    wire [10:0] H_ACT0   = std_pal ? 11'd210  : 11'd188;   // active start after H fall
    wire [11:0] H_STEP   = std_pal ? 12'd416  : 12'd421;   // input samples per pixel, 8.8
    wire [8:0]  V_AFTER  = std_pal ? 9'd2     : 9'd5;      // line number after a broad pulse
    wire [8:0]  V_ACT0   = std_pal ? 9'd24    : 9'd22;     // first stored line
    wire [8:0]  V_N      = std_pal ? 9'd288   : 9'd240;    // stored lines per field

    // ------------------------------------------------------------------
    // Stage 0: frequency -> 8-bit video code (3 pipeline steps)
    // ------------------------------------------------------------------
    reg               v0a, v0b, v0;
    reg signed [12:0] fa0, fb0, f0;
    reg [1:0]         ca0, cb0, c0;
    reg signed [13:0] fd;
    reg signed [26:0] fprod;
    reg [7:0]         s;
    wire signed [14:0] fcode = fprod[26:12] + 15'sd80;
    always @(posedge clk) begin
        v0a <= s_valid && !rst;
        v0b <= v0a;
        v0  <= v0b;
        if (s_valid) begin
            fa0 <= f_in;
            ca0 <= click;
            fd  <= f_in - lvl_off;
        end
        if (v0a) begin
            fb0   <= fa0;
            cb0   <= ca0;
            fprod <= fd * $signed({1'b0, lvl_scale});
        end
        if (v0b) begin
            f0 <= fb0;
            c0 <= cb0;
            s  <= fcode < 0 ? 8'd0 : (fcode > 15'sd255 ? 8'd255 : fcode[7:0]);
        end
    end

    // ------------------------------------------------------------------
    // Stage A: sample history, sync separator, line / field timing
    // ------------------------------------------------------------------
    reg [7:0]  x1, x2, x3, x4;
    reg        in_sync;
    reg [1:0]  run;            // consecutive samples on the other side of the threshold
    reg [10:0] hcnt;           // samples since the current line's H-sync fall
    reg [10:0] since_fall;     // samples since the last sync fall
    reg [10:0] fall_hcnt;      // hcnt at that fall
    reg [11:0] tip_noise;      // noise accumulated over the current sync tip
    reg [1:0]  ign_cnt;        // consecutive H-sync pulses rejected as out of phase

    reg [8:0]  vcount;
    reg        vreset_pend;
    reg [3:0]  vblock;         // lines to ignore further broad pulses
    reg        field_ok;       // a vertical interval was seen with a stable standard
    reg        line_act;       // the current line is stored
    reg [8:0]  lines_since_vs;
    reg        std_cand;
    reg [1:0]  std_votes;
    reg [17:0] q_acc;
    reg [20:0] lost_cnt;       // samples since the last broad pulse

    reg [11:0] bp_acc;         // back-porch sum (16 samples)
    reg [13:0] blk;            // black level, 16-sample sum with 2 fraction bits

    // level measurement on the raw frequency
    reg signed [17:0] tip_sum;     // 32 sync-tip samples
    reg signed [16:0] bpf_sum;     // 16 back-porch samples
    reg               tip_ok;      // this line's H-sync tip was measured
    reg               lvl_go;
    reg signed [12:0] tip_f, bp_f;
    reg [3:0]         clk_div;     // click prescaler: 16 clicks = 1 quality point
    wire [4:0]        csum = {1'b0, clk_div} + {3'd0, c0};

    // filtered sample (box 5) registered for stage B
    reg        va;
    reg [10:0] fa;
    reg [10:0] ha;
    reg        acta;
    reg        lsa;
    reg [8:0]  slta;
    reg        la_new;
    reg [10:0] cur_idx;

    // line-start bookkeeping (combinational helpers)
    reg        ls_event;
    reg [10:0] ls_hcnt;
    reg [17:0] q_add;

    wire [10:0] f5 = {3'd0, s} + {3'd0, x1} + {3'd0, x2} + {3'd0, x3} + {3'd0, x4};
    wire       is_low = (s < SYNC_TH);
    wire [7:0] dif = (s > x1) ? (s - x1) : (x1 - s);

    // resampler state (stage C)
    reg [18:0] pos;            // next pixel position, 11.8 samples after H fall
    reg [9:0]  px;
    reg        rs_on;

    always @(posedge clk) begin
        line_done   <= 1'b0;
        field_start <= 1'b0;
        field_end   <= 1'b0;
        va          <= 1'b0;
        lvl_go      <= 1'b0;

        if (rst) begin
            in_sync <= 1'b0; run <= 2'd0; hcnt <= 11'd0; since_fall <= 11'd0;
            fall_hcnt <= 11'd0; tip_noise <= 12'd0; ign_cnt <= 2'd0;
            vcount <= 9'd0; vreset_pend <= 1'b0; vblock <= 4'd0; field_ok <= 1'b0;
            line_act <= 1'b0; lines_since_vs <= 9'd0; std_pal <= 1'b0; std_cand <= 1'b0;
            std_votes <= 2'd0; q_acc <= 18'd0; quality <= 16'hffff; lost_cnt <= 21'd0;
            bp_acc <= 12'd0; blk <= 14'd5120; field_par <= 1'b0; line_idx <= 9'd0;
            x1 <= 8'd80; x2 <= 8'd80; x3 <= 8'd80; x4 <= 8'd80;
            tip_sum <= 18'sd0; bpf_sum <= 17'sd0; tip_ok <= 1'b0; clk_div <= 4'd0;
        end else if (v0) begin
            x1 <= s; x2 <= x1; x3 <= x2; x4 <= x3;
            hcnt <= hcnt + 11'd1;
            if (since_fall != 11'h7ff) since_fall <= since_fall + 11'd1;
            if (lost_cnt != 21'h1fffff) lost_cnt <= lost_cnt + 21'd1;
            if (lost_cnt == 21'h1ffffe) field_ok <= 1'b0;   // ~100 ms without vertical sync

            ls_event = 1'b0;
            ls_hcnt  = 11'd0;
            cur_idx  = hcnt;
            q_add    = 18'd0;

            // FM clicks on stored lines
            if (line_act) begin
                clk_div <= csum[3:0];
                q_add    = {17'd0, csum[4]};
            end

            // ---- sync separator ----
            if (!in_sync) begin
                if (is_low) begin
                    if (run == 2'd2) begin
                        in_sync    <= 1'b1;
                        run        <= 2'd0;
                        since_fall <= 11'd3;
                        fall_hcnt  <= hcnt - 11'd2;
                        tip_noise  <= 12'd0;
                        tip_sum    <= 18'sd0;
                    end else run <= run + 2'd1;
                end else run <= 2'd0;
            end else begin
                if (since_fall >= 11'd10 && since_fall < 11'd60)
                    tip_noise <= tip_noise + {6'd0, dif[7:2]};
                if (since_fall >= 11'd10 && since_fall < 11'd42)
                    tip_sum <= tip_sum + f0;
                if (!is_low) begin
                    if (run == 2'd2) begin
                        // pulse ended 2 samples ago; since_fall ~ width + 2
                        in_sync <= 1'b0;
                        run     <= 2'd0;
                        if (since_fall >= 11'd72 && since_fall < 11'd140) begin
                            // ---- H-sync ----
                            if (fall_hcnt >= {1'b0, LINE_LEN[10:1]} || ign_cnt == 2'd3) begin
                                ls_event = 1'b1;
                                ls_hcnt  = since_fall + 11'd1;
                                cur_idx  = since_fall;
                                ign_cnt  <= 2'd0;
                                tip_ok   <= 1'b1;
                                tip_f    <= tip_sum[17:5];
                                if (line_act)
                                    q_add = q_add + {6'd0, tip_noise};
                            end else
                                ign_cnt <= ign_cnt + 2'd1;
                        end else if (since_fall >= 11'd250 && vblock == 4'd0) begin
                            // ---- first broad pulse of a vertical interval ----
                            vblock      <= 4'd12;
                            vreset_pend <= 1'b1;
                            lost_cnt    <= 21'd0;
                            field_par   <= !(fall_hcnt < {2'b0, LINE_LEN[10:2]} ||
                                             fall_hcnt > LINE_LEN - {2'b0, LINE_LEN[10:2]});
                            // standard from the number of lines since the last one
                            if ((lines_since_vs > 9'd290) == std_cand) begin
                                if (std_votes != 2'd3) std_votes <= std_votes + 2'd1;
                            end else begin
                                std_cand  <= (lines_since_vs > 9'd290);
                                std_votes <= 2'd0;
                            end
                            if (std_votes >= 2'd2 && std_pal != std_cand) begin
                                std_pal  <= std_cand;
                                field_ok <= 1'b0;
                            end else begin
                                field_ok <= (std_votes >= 2'd2);
                            end
                            lines_since_vs <= 9'd0;
                            field_start    <= 1'b1;
                        end
                    end else run <= run + 2'd1;
                end else run <= 2'd0;
            end

            // ---- flywheel: bridge a missing H-sync ----
            if (!ls_event && hcnt >= LINE_LEN + 11'd160) begin
                ls_event = 1'b1;
                ls_hcnt  = hcnt - LINE_LEN + 11'd1;
                cur_idx  = hcnt - LINE_LEN;
                tip_ok   <= 1'b0;
                if (line_act) q_add = q_add + 18'd64;
            end

            // ---- black level and blanking frequency from the back porch ----
            if (hcnt >= 11'd166 && hcnt < 11'd182) begin
                bp_acc  <= bp_acc + {4'd0, s};
                bpf_sum <= bpf_sum + f0;
            end else if (hcnt == 11'd182) begin
                blk     <= blk - {3'b000, blk[13:3]} + {3'b000, bp_acc[11:1]};   // blk += (4*bp - blk)/8
                bp_acc  <= 12'd0;
                bpf_sum <= 17'sd0;
                bp_f    <= bpf_sum[16:4];
                lvl_go  <= tip_ok;
                tip_ok  <= 1'b0;
            end

            // ---- line start ----
            la_new = line_act;
            if (ls_event) begin
                hcnt <= ls_hcnt;
                if (lines_since_vs != 9'h1ff) lines_since_vs <= lines_since_vs + 9'd1;
                if (vblock != 4'd0) vblock <= vblock - 4'd1;
                if (line_act) begin
                    line_done <= 1'b1;
                    line_idx  <= vcount - V_ACT0;
                end
                if (vreset_pend) begin
                    vcount      <= V_AFTER;
                    vreset_pend <= 1'b0;
                    la_new      = 1'b0;
                end else begin
                    vcount <= vcount + 9'd1;
                    la_new = field_ok && (vcount + 9'd1 >= V_ACT0) &&
                             (vcount + 9'd1 < V_ACT0 + V_N);
                    if (field_ok && vcount + 9'd1 == V_ACT0 + V_N) begin
                        field_end <= 1'b1;
                        quality   <= (no_carrier || q_acc[17:16] != 2'd0) ? 16'hffff : q_acc[15:0];
                        q_acc     <= 18'd0;
                        q_add     = 18'd0;
                    end
                end
                line_act <= la_new;
            end
            if (q_add != 18'd0 && q_acc[17:16] == 2'd0) q_acc <= q_acc + q_add;

            // ---- to stage B ----
            va   <= 1'b1;
            fa   <= f5;
            ha   <= cur_idx;
            lsa  <= ls_event;
            acta <= la_new;
            slta <= vcount + (vreset_pend ? 9'd0 : 9'd1) - V_ACT0;   // only bit 0 used, valid at line start
        end
    end

    // ------------------------------------------------------------------
    // Level loops (once per line with a measured sync tip)
    //   off   += (blanking - off) / 8
    //   scale += (80*4096 - depth*scale) / 2048     (depth = blanking - tip)
    // The scale loop gain is depth*2/4096: ~0.4 for a 4 MHz sync depth,
    // stable up to a 10 MHz depth.
    // ------------------------------------------------------------------
    reg               lvl_go2, lvl_go3;
    reg signed [13:0] depth;
    reg signed [13:0] odiff;
    reg signed [26:0] dprod;
    wire signed [26:0] serr  = 27'sd327680 - dprod;
    wire signed [15:0] sstep = serr[26:11];
    wire signed [16:0] snew  = $signed({5'd0, lvl_scale}) + sstep;
    always @(posedge clk) begin
        lvl_go2 <= 1'b0;
        lvl_go3 <= 1'b0;
        if (rst || (v0 && lost_cnt == 21'h1ffffe)) begin
            lvl_off   <= OFF0;
            lvl_scale <= SCALE0;
        end else begin
            if (lvl_go) begin
                depth   <= bp_f - tip_f;
                odiff   <= bp_f - lvl_off;
                lvl_go2 <= 1'b1;
            end
            if (lvl_go2) begin
                dprod   <= depth * $signed({1'b0, lvl_scale});
                lvl_go3 <= depth > 14'sd100;          // > 0.5 MHz: a real sync
            end
            if (lvl_go3) begin
                lvl_off   <= lvl_off + (odiff >>> 3);
                lvl_scale <= snew < 17'sd64 ? 12'd64 : (snew > 17'sd2047 ? 12'd2047 : snew[11:0]);
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage B: luma = (f5*16 - black*5) * 327 / 16384, clamped to 0..255
    // ------------------------------------------------------------------
    reg        vb;
    reg [10:0] hb;
    reg        actb;
    reg        lsb;
    reg        sltb;
    reg [7:0]  y_cur, y_prev;
    wire signed [16:0] ydiff = $signed({2'b00, fa, 4'b0000}) -
                               $signed({1'b0, {2'b00, blk[13:2], 2'b00} + {4'b0000, blk[13:2]}});
    wire signed [26:0] yprod = ydiff * $signed(10'sd327);
    wire signed [12:0] ysh = yprod[26:14];

    always @(posedge clk) begin
        vb <= 1'b0;
        if (va) begin
            vb     <= 1'b1;
            hb     <= ha;
            actb   <= acta;
            lsb    <= lsa;
            sltb   <= slta[0];
            y_prev <= y_cur;
            y_cur  <= ysh < 0 ? 8'd0 : (ysh > 13'sd255 ? 8'd255 : ysh[7:0]);
        end
    end

    // ------------------------------------------------------------------
    // Stage C: horizontal resampler (y_prev = sample hb-1, y_cur = sample hb)
    // ------------------------------------------------------------------
    wire signed [8:0]  ystep = $signed({1'b0, y_cur}) - $signed({1'b0, y_prev});
    wire signed [17:0] yint  = ystep * $signed({1'b0, pos[7:0]});
    wire [8:0]         yo    = {1'b0, y_prev} + yint[16:8];

    reg rs_slot;
    always @(posedge clk) begin
        pix_we <= 1'b0;
        if (rst) begin
            rs_on <= 1'b0;
            px    <= 10'd0;
            pos   <= 19'd0;
        end else if (vb) begin
            if (lsb) begin
                px      <= 10'd0;
                pos     <= {H_ACT0, 8'd0};
                rs_on   <= actb;
                rs_slot <= sltb;
            end else if (rs_on && pos[18:8] == hb - 11'd1) begin
                pix_we   <= 1'b1;
                pix_x    <= px;
                pix_y    <= yo[7:0];
                pix_slot <= rs_slot;
                px       <= px + 10'd1;
                pos      <= pos + {7'd0, H_STEP};
                if (px == 10'd639) rs_on <= 1'b0;
            end
        end
    end

endmodule
