// CVBS decoder for one channel (monochrome stage).
//
// Input: recovered 20 MS/s 6-bit samples (C5VRX levels: sync 0, blank 20,
// white ~60).  Output: 640 luma pixels per active line of each field, plus
// line / field events for the frame-buffer writer.
//
//  - Sync separator with hysteresis; pulses are classified by width into
//    H-sync (~94 samples), equalising (~47) and broad (vertical, ~540).
//  - Line timing is a flywheel: H-sync re-aligns it, missing pulses (and the
//    vertical interval, which has no H-sync) are bridged at the line period.
//  - The first broad pulse of a vertical interval starts a field.  Its phase
//    against the line timing gives the field parity; the line count between
//    vertical intervals selects NTSC (262/263) or PAL (312/313).
//  - Luma: 5-tap box filter (notches the 3.58 / 4.43 MHz sub-carrier), black
//    level clamped to the back porch, gain fixed to C5VRX's 40-code range.
//  - Horizontal: the active line (52.6 us NTSC / 52.0 us PAL) is resampled to
//    640 pixels with linear interpolation.
//  - Quality (lower is better) for diversity: sync-tip noise of the H-sync
//    pulses plus a penalty per line whose H-sync was missing.
module cvbs_decode (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire [5:0]  s,

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
    output reg  [15:0] quality
);

    localparam [5:0] SYNC_TH = 6'd10;

    wire [10:0] LINE_LEN = std_pal ? 11'd1280 : 11'd1271;
    wire [10:0] H_ACT0   = std_pal ? 11'd210  : 11'd188;   // active start after H fall
    wire [11:0] H_STEP   = std_pal ? 12'd416  : 12'd421;   // input samples per pixel, 8.8
    wire [8:0]  V_AFTER  = std_pal ? 9'd2     : 9'd5;      // line number after a broad pulse
    wire [8:0]  V_ACT0   = std_pal ? 9'd24    : 9'd22;     // first stored line
    wire [8:0]  V_N      = std_pal ? 9'd288   : 9'd240;    // stored lines per field

    // ------------------------------------------------------------------
    // Stage A: sample history, sync separator, line / field timing
    // ------------------------------------------------------------------
    reg [5:0]  x1, x2, x3, x4;
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

    reg [9:0]  bp_acc;         // back-porch sum (16 samples)
    reg [11:0] blk;            // black level, 16-sample sum with 2 fraction bits

    // filtered sample (box 5) registered for stage B
    reg        va;
    reg [8:0]  fa;
    reg [10:0] ha;
    reg        acta;
    reg        lsa;
    reg [8:0]  slta;
    reg        la_new;
    reg [10:0] cur_idx;

    // line-start bookkeeping (combinational helpers)
    reg        ls_event;
    reg [10:0] ls_hcnt;

    wire [8:0] f5 = {3'd0, s} + {3'd0, x1} + {3'd0, x2} + {3'd0, x3} + {3'd0, x4};
    wire       is_low = (s < SYNC_TH);
    wire [5:0] dif = (s > x1) ? (s - x1) : (x1 - s);

    // resampler state (stage C)
    reg [18:0] pos;            // next pixel position, 11.8 samples after H fall
    reg [9:0]  px;
    reg        rs_on;

    always @(posedge clk) begin
        line_done   <= 1'b0;
        field_start <= 1'b0;
        field_end   <= 1'b0;
        va          <= 1'b0;

        if (rst) begin
            in_sync <= 1'b0; run <= 2'd0; hcnt <= 11'd0; since_fall <= 11'd0;
            fall_hcnt <= 11'd0; tip_noise <= 12'd0; ign_cnt <= 2'd0;
            vcount <= 9'd0; vreset_pend <= 1'b0; vblock <= 4'd0; field_ok <= 1'b0;
            line_act <= 1'b0; lines_since_vs <= 9'd0; std_pal <= 1'b0; std_cand <= 1'b0;
            std_votes <= 2'd0; q_acc <= 18'd0; quality <= 16'hffff; lost_cnt <= 21'd0;
            bp_acc <= 10'd0; blk <= 12'd1280; field_par <= 1'b0; line_idx <= 9'd0;
            x1 <= 6'd20; x2 <= 6'd20; x3 <= 6'd20; x4 <= 6'd20;
        end else if (s_valid) begin
            x1 <= s; x2 <= x1; x3 <= x2; x4 <= x3;
            hcnt <= hcnt + 11'd1;
            if (since_fall != 11'h7ff) since_fall <= since_fall + 11'd1;
            if (lost_cnt != 21'h1fffff) lost_cnt <= lost_cnt + 21'd1;
            if (lost_cnt == 21'h1ffffe) field_ok <= 1'b0;   // ~100 ms without vertical sync

            ls_event = 1'b0;
            ls_hcnt  = 11'd0;
            cur_idx  = hcnt;

            // ---- sync separator ----
            if (!in_sync) begin
                if (is_low) begin
                    if (run == 2'd2) begin
                        in_sync    <= 1'b1;
                        run        <= 2'd0;
                        since_fall <= 11'd3;
                        fall_hcnt  <= hcnt - 11'd2;
                        tip_noise  <= 12'd0;
                    end else run <= run + 2'd1;
                end else run <= 2'd0;
            end else begin
                if (since_fall >= 11'd10 && since_fall < 11'd60)
                    tip_noise <= tip_noise + {6'd0, dif};
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
                                if (line_act)
                                    q_acc <= q_acc + {6'd0, tip_noise};
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
                if (line_act) q_acc <= q_acc + 18'd64;
            end

            // ---- black level from the back porch ----
            if (hcnt >= 11'd166 && hcnt < 11'd182)
                bp_acc <= bp_acc + {4'd0, s};
            else if (hcnt == 11'd182) begin
                blk    <= blk - {3'b000, blk[11:3]} + {3'b000, bp_acc[9:1]};   // blk += (4*bp - blk)/8
                bp_acc <= 10'd0;
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
                        quality   <= (q_acc[17:16] != 2'd0) ? 16'hffff : q_acc[15:0];
                        q_acc     <= 18'd0;
                    end
                end
                line_act <= la_new;
            end

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
    // Stage B: luma = (f5*16 - black*5) * 327 / 4096, clamped to 0..255
    // ------------------------------------------------------------------
    reg        vb;
    reg [10:0] hb;
    reg        actb;
    reg        lsb;
    reg        sltb;
    reg [7:0]  y_cur, y_prev;
    wire signed [14:0] ydiff = $signed({2'b00, fa, 4'b0000}) -
                               $signed({1'b0, {2'b00, blk[11:2], 2'b00} + {4'b0000, blk[11:2]}});
    wire signed [24:0] yprod = ydiff * $signed(10'sd327);
    wire signed [12:0] ysh = yprod[24:12];

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
