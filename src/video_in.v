// NTSC sync separator and line sampler on the demodulator output
// (IQ domain, 84.375 MHz clock, vid valid at ~80 MS/s; all times below are
// in valid samples, 80 per us).
//
// Sync: the slicing threshold is half way between the sync tip and the
// black level (back porch), both averaged over real lines. Until 16 lines
// have given both, it falls back to a quarter of the way up from the
// tracked minimum to the tracked peak; that fallback alone cuts into black
// picture parts when bright OSD text widens the peak (seen on the board:
// false line starts and white bands on OSD lines). Pulses below the
// threshold are classed by width: H 3..8 us, equalising 1..3 us, broad
// (vertical) > 15 us.
// Line starts: a H pulse at least 0.8 line after the last line start is
// one; without it, a line start is synthesised one line period (L = 5085)
// after the last, so lines keep counting through the vertical interval and
// over lost pulses.
// Field: the first broad pulse starts a field (line count n = 0). Its
// distance from the last line start tells the field parity (half a line).
// Lines n = FIRST .. FIRST + 239 are the 240 active lines of the field.
//
// Level: per line the back porch (5.6..7.2 us after the sync edge, over
// the burst) is the black level, and the sync tip (first 3.2 us of the
// pulse) gives the sync depth S. White is taken as black + 2.5 S
// (40 IRE sync, 100 IRE white): luma = (vid - black) * K >> 12,
// K = 255 * 4096 / (2.5 S), S averaged over lines.
// Pixels: 1280 per line from 9.4 us after the sync edge, 3 per 10 samples
// (24 MS/s, 53.3 us), written as 8-bit luma to a 16-line ring:
// address = {active line [3:0], pixel [10:0]}.
module video_in #(
    parameter FIRST = 16
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [13:0] vid,
    output reg                we,
    output reg  [14:0]        waddr,
    output reg  [7:0]         wdata,
    output reg                field_tg,     // toggles when active line 0 is written
    output reg                parity,
    output reg  [15:0]        real_lines,   // real H line starts per field, for display
    output reg  [15:0]        field_lines   // all line starts per field
);
    localparam [23:0] L        = 24'd5085;
    localparam [23:0] L_MIN    = 24'd4068;   // 0.8 L
    localparam [23:0] L_SYNTH  = 24'd5594;   // 1.1 L
    localparam [12:0] PORCH_A  = 13'd450;
    localparam [12:0] PORCH_B  = 13'd578;    // 128 samples
    localparam [12:0] DIV_AT   = 13'd600;
    localparam [12:0] ACT      = 13'd752;    // 9.4 us

    reg [23:0] t;
    always @(posedge clk) if (rst) t <= 0; else if (in_valid) t <= t + 24'd1;

    // ---- levels and threshold ----
    reg signed [13:0] mn, mx, thr;
    reg [7:0] decay;
    reg signed [13:0] tip_f, black_f;   // averaged over real lines (below)
    reg [4:0]  lvl_n;                   // real lines that gave both, up to 16
    wire signed [14:0] mid = tip_f + black_f;
    always @(posedge clk) begin
        if (rst) begin
            mn <= 0; mx <= 0; thr <= 0;
        end else if (in_valid) begin
            decay <= decay + 8'd1;
            if (vid < mn) mn <= vid; else if (&decay) mn <= mn + 14'sd1;
            if (vid > mx) mx <= vid; else if (&decay) mx <= mx - 14'sd1;
            thr <= lvl_n[4] ? mid[14:1] : mn + ((mx - mn) >>> 2);
        end
    end

    // ---- pulses ----
    reg        below;
    reg [23:0] t_fall;
    reg [23:0] width;
    reg        pulse_end;          // one clock after a pulse ended
    reg [8:0]  tip_n;
    reg signed [21:0] tip_sum;
    reg signed [13:0] tip;
    always @(posedge clk) begin
        pulse_end <= 1'b0;
        if (rst) begin
            below <= 1'b0;
        end else if (in_valid) begin
            if (!below && vid < thr) begin
                below   <= 1'b1;
                t_fall  <= t;
                tip_n   <= 0;
                tip_sum <= 0;
            end else if (below && vid >= thr) begin
                below     <= 1'b0;
                width     <= t - t_fall;
                pulse_end <= 1'b1;
                if (tip_n[8]) tip <= tip_sum[21:8];
            end else if (below && !tip_n[8]) begin
                tip_n   <= tip_n + 9'd1;
                tip_sum <= tip_sum + vid;
            end
        end
    end
    wire is_h     = pulse_end && width >= 24'd240 && width < 24'd640;
    wire is_broad = pulse_end && width >= 24'd1200;

    // ---- line starts and field ----
    reg [23:0] last_line;
    reg [9:0]  n;
    reg        in_v;
    reg        line_ev, line_real;
    reg [23:0] lt;                 // current line start
    wire [23:0] since_last = t - last_line;
    wire [23:0] fall_gap   = t_fall - last_line;

    always @(posedge clk) begin
        line_ev <= 1'b0;
        if (rst) begin
            last_line <= 0;
            n <= 10'd1023;
            in_v <= 1'b0;
        end else begin
            if (is_h && fall_gap >= L_MIN) begin
                line_ev   <= 1'b1;
                line_real <= 1'b1;
                lt        <= t_fall;
                last_line <= t_fall;
                in_v      <= 1'b0;
                if (n != 10'd1023) n <= n + 10'd1;
            end else if (since_last >= L_SYNTH) begin
                line_ev   <= 1'b1;
                line_real <= 1'b0;
                lt        <= last_line + L;
                last_line <= last_line + L;
                if (n != 10'd1023) n <= n + 10'd1;
            end
            if (is_broad && !in_v) begin
                in_v   <= 1'b1;
                n      <= 10'd0;
                parity <= (fall_gap >= 24'd1271) && (fall_gap < 24'd3813);
            end
        end
    end

    // Per-field statistics: counted from one field start to the next.
    reg [15:0] rl_cnt, fl_cnt;
    always @(posedge clk) begin
        if (is_broad && !in_v) begin
            real_lines  <= rl_cnt;
            field_lines <= fl_cnt;
            rl_cnt <= 0;
            fl_cnt <= 0;
        end else if (line_ev) begin
            fl_cnt <= fl_cnt + 16'd1;
            if (line_real) rl_cnt <= rl_cnt + 16'd1;
        end
    end

    // ---- per-line timing ----
    wire [23:0] rel24 = t - lt;
    wire [12:0] rel   = (rel24 > 24'd8191) ? 13'd8191 : rel24[12:0];
    reg  [9:0]  idx_n;
    reg         active;
    always @(posedge clk) if (line_ev) begin
        active <= (n >= FIRST) && (n < FIRST + 240);
        idx_n  <= n - FIRST;
    end

    // Black level and sync depth.
    reg signed [20:0] psum;
    reg signed [13:0] black;
    reg signed [13:0] s_avg;
    wire signed [14:0] s_line = black - tip;
    always @(posedge clk) begin
        if (rst) begin
            s_avg <= 14'sd200;
            lvl_n <= 0;
        end else if (in_valid && line_real) begin
            if (rel == PORCH_A) psum <= vid;
            else if (rel > PORCH_A && rel < PORCH_B) psum <= psum + vid;
            else if (rel == PORCH_B) begin
                black <= psum[20:7];
            end else if (rel == PORCH_B + 13'd1) begin
                if (s_line > 15'sd40 && s_line < 15'sd4000) begin
                    s_avg <= s_avg + ((s_line - s_avg) >>> 3);
                    if (lvl_n[4]) begin
                        tip_f   <= tip_f + ((tip - tip_f) >>> 3);
                        black_f <= black_f + ((black - black_f) >>> 3);
                    end else begin
                        tip_f   <= tip;
                        black_f <= black;
                        lvl_n   <= lvl_n + 5'd1;
                    end
                end
            end
        end
    end

    // K = 417792 / s_avg, restoring division once per line.
    reg [18:0] k_rem;
    reg [18:0] k_q;
    reg [13:0] k_div;
    reg [4:0]  k_i;
    reg        k_busy;
    reg [12:0] gain;
    always @(posedge clk) begin
        if (rst) begin
            k_busy <= 1'b0;
            gain   <= 13'd2089;           // for s_avg = 200
        end else if (!k_busy && in_valid && rel == DIV_AT) begin
            k_busy <= 1'b1;
            k_rem  <= 0;
            k_q    <= 19'd417792;
            k_div  <= (s_avg < 14'sd32) ? 14'd32 : s_avg;
            k_i    <= 5'd19;
        end else if (k_busy) begin
            if (k_i != 0) begin
                if ({k_rem[17:0], k_q[18]} >= {5'd0, k_div}) begin
                    k_rem <= {k_rem[17:0], k_q[18]} - {5'd0, k_div};
                    k_q   <= {k_q[17:0], 1'b1};
                end else begin
                    k_rem <= {k_rem[17:0], k_q[18]};
                    k_q   <= {k_q[17:0], 1'b0};
                end
                k_i <= k_i - 5'd1;
            end else begin
                k_busy <= 1'b0;
                gain   <= (k_q > 19'd8191) ? 13'd8191 : k_q[12:0];
            end
        end
    end

    // ---- pixels: 3 per 10 samples from ACT ----
    reg [3:0]  frac;
    reg [10:0] px;
    reg        p_v;
    reg [10:0] p_px;
    reg signed [14:0] p_d;
    always @(posedge clk) begin
        p_v <= 1'b0;
        if (line_ev) begin
            frac <= 0;
            px   <= 0;
        end else if (in_valid && active && rel >= ACT && px < 11'd1280) begin
            if (frac + 4'd3 >= 4'd10) begin
                frac <= frac + 4'd3 - 4'd10;
                p_v  <= 1'b1;
                p_px <= px;
                p_d  <= vid - black;
                px   <= px + 11'd1;
            end else begin
                frac <= frac + 4'd3;
            end
        end
    end

    // luma = clamp((d * gain) >> 12), two stages.
    reg        m_v;
    reg [10:0] m_px;
    reg signed [28:0] m_prod;
    always @(posedge clk) begin
        m_v    <= p_v;
        m_px   <= p_px;
        m_prod <= p_d * $signed({1'b0, gain});
    end
    always @(posedge clk) begin
        we <= m_v;
        if (m_v) begin
            waddr <= {idx_n[3:0], m_px};
            if (m_prod < 0)                    wdata <= 8'd0;
            else if (m_prod[28:12] > 17'd255)  wdata <= 8'd255;
            else                               wdata <= m_prod[19:12];
        end
    end

    always @(posedge clk) begin
        if (rst) field_tg <= 1'b0;
        else if (m_v && idx_n == 10'd0 && m_px == 11'd1279) field_tg <= ~field_tg;
    end
endmodule
