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
// Line starts: a line PLL predicts each line start one period after the
// last; H pulses near the prediction are real lines, otherwise the line is
// synthesised (see "line PLL" below).
// Field: the first broad pulse 250+ lines after the last field start starts
// a field (line count n = 0); its distance from the last line start tells
// the field parity (half a line). Without one, a field is synthesised.
// Lines n = first .. first + 239 are the 240 active lines of the field
// (first and the picture start act are runtime settings from the UART).
//
// Level: per line the back porch (0.5..2.1 us after the sync trailing edge, over
// the burst) is the black level, and the sync tip (first 3.2 us of the
// pulse) gives the sync depth S. White is taken as black + 2.5 S
// (40 IRE sync, 100 IRE white): luma = (vid - black) * K >> 12,
// K = 255 * 4096 / (2.5 S), S averaged over lines.
// Colour (chroma.v): per line burst reference on the back porch; per pixel
// U = -Re(M conj(R)), V = Im(M conj(R)), normalised to the burst (the
// display inverts V by default: that gave natural hues on the board).
// Pixels: 640 per line from act (default 9.4 us) after the sync edge,
// 3 per 20 samples (12 MS/s, 53.3 us), written to a 32-line ring as
// {Y, C}: Y 8-bit luma, C signed 8-bit U on even and V on odd pixels;
// address = (active line mod 32) * 640 + pixel. 16 lines were too few: the
// 720p output uses 66.75 us per field line against 63.56 us coming in, so
// by the bottom it trails by ~12 lines plus its start and interpolation
// look-ahead (seen as doubled OSD text in the lowest ~100 rows).
module video_in (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [13:0] vid,
    input  wire signed [9:0]  d,
    input  wire [9:0]         first,
    input  wire [12:0]        act,
    output reg                we,
    output reg  [14:0]        waddr,
    output reg  [15:0]        wdata,
    output reg                field_tg,     // toggles when active line 2 is written
    output reg                parity,
    output reg  [15:0]        real_lines,   // real H line starts per field, for display
    output reg  [15:0]        field_lines,  // all line starts per field
    output wire [255:0]       status,       // for the UART 'T' command
    input  wire [15:0]        jumps,        // output frame re-acquisitions (pixel domain, display only)
    output wire               cdbg_v,       // chroma debug stream (UART 'G')
    output wire [31:0]        cdbg_w
);
    localparam [23:0] L        = 24'd5085;
    // Back porch windows are timed from the sync trailing edge (rel_r): the
    // line start is only known once the pulse has ended (+ 0.3 us debounce),
    // which with the 5.4..6.2 us pulse width at the slicing level was later
    // than a 5.5 us window from the leading edge (measured burst 1/10 of the
    // host result, wrong black level).
    localparam [12:0] PORCH_A  = 13'd40;     // 0.5 us after the trailing edge
    localparam [12:0] PORCH_B  = 13'd168;    // 128 samples
    localparam [12:0] DIV_AT   = 13'd210;
    localparam [12:0] BURST_A  = 13'd40;     // 160 samples

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
    reg [23:0] t_rise;
    reg        pulse_end;          // one clock after a pulse ended
    reg        fall_ev;            // one clock after a pulse started
    reg [8:0]  tip_n;
    reg signed [21:0] tip_sum;
    reg signed [13:0] tip;
    // A crossing counts only after DB samples (0.3 us) on the other side,
    // so noise spikes neither start pulses nor cut broad pulses apart (seen
    // on a weaker signal: missed field starts). Edge times are corrected
    // back by DB.
    localparam [4:0] DB = 5'd24;
    reg [4:0] other;
    wire cross = below ? (vid >= thr) : (vid < thr);
    always @(posedge clk) begin
        pulse_end <= 1'b0;
        fall_ev   <= 1'b0;
        if (rst) begin
            below <= 1'b0;
            other <= 0;
        end else if (in_valid) begin
            other <= cross ? other + 5'd1 : 5'd0;
            if (cross && other == DB - 5'd1) begin
                other <= 0;
                if (!below) begin
                    below   <= 1'b1;
                    fall_ev <= 1'b1;
                    t_fall  <= t - DB + 24'd1;
                    tip_n   <= 0;
                    tip_sum <= 0;
                end else begin
                    below     <= 1'b0;
                    width     <= t - DB + 24'd1 - t_fall;
                    t_rise    <= t - DB + 24'd1;
                    pulse_end <= 1'b1;
                    if (tip_n[8]) tip <= tip_sum[21:8];
                end
            end else if (below && !tip_n[8]) begin
                tip_n   <= tip_n + 9'd1;
                tip_sum <= tip_sum + vid;
            end
        end
    end
    wire is_h     = pulse_end && width >= 24'd240 && width < 24'd640;
    wire is_broad = pulse_end && width >= 24'd1200;

    // ---- line starts: line PLL ----
    // The next line start is predicted one line period after the last one.
    // A sync pulse whose falling edge is within +-W of the prediction starts
    // the line at once (its own edge, so the picture does not jitter); when
    // the pulse ends as a H pulse the line counts as real (only real lines
    // measure the porch and burst). Without an edge by the end of the window
    // the line is synthesised at the prediction, which also counts lines
    // through the vertical interval. Eight H pulses in a row one line apart
    // outside the window move the PLL to them; 300 lines without a real H
    // unlock it and the next H is taken as it is.
    // The first version accepted any H 0.8 line after the last line start
    // and synthesised 1.1 line after it. One noise pulse mid-line then put
    // its phase half a line off, every real H after it looked early, and it
    // never came back while the picture itself was still fine (field test:
    // 1..4 real lines per field at 24 dB video SNR). A H pulse is only known
    // when it ends (~6 us), so the line starts at the falling edge here; a
    // version that waited for the pulse end synthesised every line first.
    // The idea of a PLL line grid that only takes pulses near its prediction
    // follows the C5VRX-4 sync flywheel (legacy/c5vrx4/SYNC_FLYWHEEL.md,
    // C5VRX by Twotoz and the C5VRX contributors).
    // While locked a line starts at the prediction, not at its own edge:
    // starting at the edge moved every line by the edge noise (4 x 64-us
    // captures at close range: 1.4 samples rms, 5 p-p, several times more
    // on a weaker signal), seen as horizontal wobble. The prediction is a
    // second-order loop in 1/256 sample: each real H compares its pulse
    // centre (half the noise of one edge) less the average half width with
    // the line start, and moves the next start by e/16 and the period by
    // e/1024 (host simulation: line-to-line jitter 0.26 sample at 4 samples
    // rms edge noise, 0.06 at 1; period offsets of 0.3 sample/line settle
    // in ~100 lines). Lines whose pulse is not a H (noise, vertical
    // interval) leave the loop alone.
    localparam [23:0] W     = 24'd200;       // 2.5 us
    localparam [23:0] W_SYN = 24'd240;       // no edge by then: synthesise
    localparam [23:0] PER0  = 24'd1301606;   // 5084.4 samples (63.555 us)
    localparam [23:0] PER_LO = 24'd1299456;  // 5076
    localparam [23:0] PER_HI = 24'd1303552;  // 5092
    reg [31:0] lt_q, nxt_q;                  // line start / next start, 1/256 sample
    reg [23:0] per_q;                        // line period, 1/256 sample
    reg [19:0] hw_q;                         // average half width of H, 1/256 sample
    reg        hw_ok;
    wire [23:0] next_lt = nxt_q[31:8];
    reg        locked;
    reg [8:0]  miss;
    reg [23:0] cand_last;
    reg [3:0]  cand_cnt;
    reg        pend;                         // this line's pulse has not ended yet
    reg [9:0]  n;
    reg        in_v;
    reg        line_ev, line_real;
    reg [23:0] lt;                 // current line start (sync leading edge)
    reg [23:0] lr;                 // its sync trailing edge (real lines)
    wire [23:0] e_raw   = t_fall - next_lt;
    wire        in_win  = ($signed(e_raw) >= -$signed(W)) && ($signed(e_raw) <= $signed(W));
    wire [23:0] c_raw   = t_fall - cand_last - L;
    wire        cand_ok = ($signed(c_raw) >= -$signed(W)) && ($signed(c_raw) <= $signed(W));
    wire [23:0] late    = t - next_lt;
    wire        start_e = fall_ev && (!locked || in_win);           // line starts at this edge
    wire        reacq   = is_h && !pend && cand_ok && (cand_cnt >= 4'd7);
    wire [23:0] fall_gap = t_fall - lt;      // broad pulse from the last line start

    // ---- field: vertical sync with a flywheel ----
    // Vertical sync is found from the fraction of time below the slicing
    // level: a leaky integrator (time constant 1024 samples, 12.8 us) of
    // "below" crosses 0.6 of full scale ~940 samples into a broad pulse
    // (27 us) but never on a H pulse (4.7 us: 0.31) or the equalising
    // pulses. Requiring one unbroken pulse of 15 us (the first version)
    // failed on weak signals: noise cut the broad pulses apart and nearly
    // every field had to be synthesised (field test, 20..26 dB video SNR).
    // A crossing starts a field 258..268 lines after the last field start
    // (where it belongs), or whenever it comes 260..266 lines after the
    // previous crossing (a regular vertical sync wins over the synthesised
    // phase; without this a synthesised phase that drifted off never let a
    // real sync in again: the field test saw no real field at all). Taking
    // any crossing 250+ lines on let noise crossings up to 12 lines early
    // move the field, and the output lock re-acquired several times a
    // second on a weak signal. Without one the field is synthesised 268
    // lines after the last start, continuing at line 5 or 6 alternately:
    // 262.5 lines per field on average. (Continuing at a fixed line gave
    // 262-line fields, half a line short each, which the output lock could
    // not follow: it re-acquired almost every frame.)
    localparam [20:0] V_ON  = 21'd629146;   // 0.6 * 2^20
    localparam [20:0] V_OFF = 21'd314573;   // 0.3 * 2^20, re-arm
    localparam [23:0] V_LAG = 24'd938;      // crossing delay into the pulse
    reg  [20:0] vacc;
    reg         v_armed, vs_ev;
    reg  [23:0] t_vs;
    always @(posedge clk) begin
        vs_ev <= 1'b0;
        if (rst) begin
            vacc <= 0; v_armed <= 1'b1;
        end else if (in_valid) begin
            vacc <= vacc + ((vid < thr) ? 21'd1024 : 21'd0) - {10'd0, vacc[20:10]};
            if (v_armed && vacc >= V_ON) begin
                vs_ev   <= 1'b1;
                v_armed <= 1'b0;
                t_vs    <= t - V_LAG;
            end else if (!v_armed && vacc < V_OFF) begin
                v_armed <= 1'b1;
            end
        end
    end
    wire [23:0] vs_gap  = t_vs - lt;        // broad pulse start from the last line start
    wire        vs_par  = (vs_gap >= 24'd1271) && (vs_gap < 24'd3813);
    reg  [9:0]  m_vs;                       // lines since the last crossing
    always @(posedge clk) begin
        if (rst || vs_ev)                 m_vs <= 0;
        else if (line_ev && m_vs != 10'd1023) m_vs <= m_vs + 10'd1;
    end
    wire fs_real  = vs_ev && ((n >= 10'd258 && n <= 10'd268) || (n == 10'd1023) ||
                              (m_vs >= 10'd260 && m_vs <= 10'd266));
    wire fs_synth = line_ev && (n == 10'd268);

    // Loop error of a real H (pulse centre - half width - line start),
    // limited to the window; three pipeline stages after the pulse end
    // (the next line is thousands of samples away).
    wire [31:0] e_c   = {t_fall, 8'd0} + {1'b0, width[23:0], 7'd0} - {12'd0, hw_q} - lt_q;
    reg  signed [31:0] e_s;
    reg  signed [31:0] e_l;
    reg  [1:0]  e_v;
    wire signed [27:0] e_lp  = e_l >>> 4;
    wire signed [24:0] per_n = $signed({1'b0, per_q}) + (e_l >>> 10);
    wire signed [25:0] hw_d  = $signed({1'b0, width[12:0], 7'd0}) - $signed({1'b0, hw_q});
    always @(posedge clk) begin
        e_s <= $signed(e_c);
        e_l <= (e_s > $signed({W, 8'd0}))  ? $signed({W, 8'd0}) :
               (e_s < -$signed({W, 8'd0})) ? -$signed({W, 8'd0}) : e_s;
        e_v <= {e_v[0], pulse_end && pend && is_h && hw_ok && !rst};
    end

    always @(posedge clk) begin
        line_ev <= 1'b0;
        if (rst) begin
            locked <= 1'b0; miss <= 0; cand_cnt <= 0; pend <= 1'b0;
            n <= 10'd1023; in_v <= 1'b0;
            per_q <= PER0; hw_ok <= 1'b0;
        end else begin
            if (start_e || reacq) begin
                line_ev   <= 1'b1;
                line_real <= reacq;
                if (locked && !reacq) begin  // edge in the window: the prediction
                    lt    <= nxt_q[31:8];
                    lt_q  <= nxt_q;
                    nxt_q <= nxt_q + {8'd0, per_q};
                end else begin               // (re)acquire at the edge
                    lt    <= t_fall;
                    lt_q  <= {t_fall, 8'd0};
                    nxt_q <= {t_fall, 8'd0} + {8'd0, per_q};
                end
                if (reacq) lr <= t_rise;
                locked    <= 1'b1;
                pend      <= !reacq;
                cand_cnt  <= 0;
                if (reacq) begin miss <= 0; in_v <= 1'b0; end
                if (n != 10'd1023) n <= n + 10'd1;
            end else if (locked && ($signed(late) > $signed(W_SYN))) begin
                line_ev   <= 1'b1;
                line_real <= 1'b0;
                lt        <= nxt_q[31:8];
                lt_q      <= nxt_q;
                nxt_q     <= nxt_q + {8'd0, per_q};
                pend      <= 1'b0;
                if (miss == 9'd300) locked <= 1'b0; else miss <= miss + 9'd1;
                if (n != 10'd1023) n <= n + 10'd1;
            end
            if (pulse_end) begin
                if (pend) begin               // the pulse that started this line
                    pend <= 1'b0;
                    if (is_h) begin
                        line_real <= 1'b1;
                        lr        <= t_rise;
                        miss      <= 0;
                        in_v      <= 1'b0;
                        hw_q  <= hw_ok ? hw_q + hw_d[25:6] : {width[12:0], 7'd0};
                        hw_ok <= 1'b1;
                    end
                end else if (is_h && !reacq) begin   // a H outside the window
                    cand_cnt  <= cand_ok ? ((cand_cnt == 4'd15) ? cand_cnt : cand_cnt + 4'd1) : 4'd1;
                    cand_last <= t_fall;
                end
            end
            if (e_v[1]) begin
                nxt_q <= nxt_q + {{4{e_lp[27]}}, e_lp};
                per_q <= (per_n < $signed({1'b0, PER_LO})) ? PER_LO :
                         (per_n > $signed({1'b0, PER_HI})) ? PER_HI : per_n[23:0];
            end
            if (fs_real) begin
                in_v   <= 1'b1;
                n      <= 10'd0;
                parity <= vs_par;
            end else if (fs_synth) begin
                n      <= parity ? 10'd5 : 10'd6;   // 268 - 262.5 on average; other parity
                parity <= ~parity;
            end
        end
    end

    // Per-field statistics: counted from one field start to the next.
    reg [15:0] rl_cnt, fl_cnt;
    always @(posedge clk) begin
        if (fs_real || fs_synth) begin
            real_lines  <= rl_cnt;
            field_lines <= fl_cnt;
            rl_cnt <= 0;
            fl_cnt <= 0;
        end else begin
            if (line_ev) fl_cnt <= fl_cnt + 16'd1;
            // a line becomes real when its pulse ends as H (or on re-acquire)
            if ((pulse_end && pend && is_h) || (line_ev && reacq)) rl_cnt <= rl_cnt + 16'd1;
        end
    end

    // ---- per-line timing ----
    wire [23:0] rel24 = t - lt;
    wire [12:0] rel   = (rel24 > 24'd8191) ? 13'd8191 : rel24[12:0];
    wire [23:0] relr24 = t - lr;
    wire [12:0] rel_r = (relr24 > 24'd8191) ? 13'd8191 : relr24[12:0];
    reg  [9:0]  idx_n;
    reg         active;
    always @(posedge clk) if (line_ev) begin
        active <= (n >= first) && (n < first + 10'd240);
        idx_n  <= n - first;
    end

    // Colour reference and mixing.
    wire signed [15:0] mc, ms;
    wire signed [13:0] uc, us;
    wire [17:0]        gc;
    wire [47:0]        c_dbg;
    chroma u_chroma (
        .clk(clk), .rst(rst), .in_valid(in_valid), .d(d),
        .burst_gate(line_real && rel_r >= BURST_A && rel_r < BURST_A + 13'd160),
        .mc(mc), .ms(ms), .uc(uc), .us(us), .gc(gc), .dbg(c_dbg),
        .dbg_v(cdbg_v), .dbg_w(cdbg_w)
    );

    // Black level and sync depth.
    reg signed [20:0] psum;
    reg signed [13:0] black;
    reg signed [13:0] s_avg;
    wire signed [14:0] s_line = black - tip;
    // Levels learned on noise (VTX off) can put the threshold below the real
    // sync tip, and then no pulse ever ends a line to correct them (seen on
    // the board): without a real H for 2^21 samples (26 ms) start over.
    reg [20:0] no_h;
    always @(posedge clk) begin
        if (rst || is_h)       no_h <= 0;
        else if (in_valid && !(&no_h)) no_h <= no_h + 21'd1;
    end
    always @(posedge clk) begin
        if (rst || &no_h) begin
            s_avg <= 14'sd200;
            lvl_n <= 0;
        end else if (in_valid && line_real) begin
            if (rel_r == PORCH_A) psum <= vid;
            else if (rel_r > PORCH_A && rel_r < PORCH_B) psum <= psum + vid;
            else if (rel_r == PORCH_B) begin
                black <= psum[20:7];
            end else if (rel_r == PORCH_B + 13'd1) begin
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
        end else if (!k_busy && in_valid && rel_r == DIV_AT) begin
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

    // ---- pixels: 3 per 20 samples from act ----
    reg [4:0]  frac;
    reg [9:0]  px;
    reg        p_v;
    reg [9:0]  p_px;
    reg signed [14:0] p_d;
    reg signed [15:0] p_mc, p_ms;
    always @(posedge clk) begin
        p_v <= 1'b0;
        if (line_ev) begin
            frac <= 0;
            px   <= 0;
        end else if (in_valid && active && rel >= act && px < 10'd640) begin
            if (frac + 5'd3 >= 5'd20) begin
                frac <= frac + 5'd3 - 5'd20;
                p_v  <= 1'b1;
                p_px <= px;
                p_d  <= vid - black;
                p_mc <= mc;
                p_ms <= ms;
                px   <= px + 10'd1;
            end else begin
                frac <= frac + 5'd3;
            end
        end
    end

    // Stage 1: luma product, chroma rotation by the unit burst vector.
    reg        m_v;
    reg [9:0]  m_px;
    reg signed [28:0] m_prod;
    reg signed [30:0] t1, t2;
    always @(posedge clk) begin
        m_v    <= p_v;
        m_px   <= p_px;
        m_prod <= p_d * $signed({1'b0, gain});
        t1     <= p_mc * uc + p_ms * us;      // Re(M conj B)
        t2     <= p_ms * uc - p_mc * us;      // Im(M conj B)
    end

    // Stage 2: chroma gain (ACC).
    reg        n_v;
    reg [9:0]  n_px;
    reg signed [28:0] n_prod;
    reg signed [37:0] cu, cv;
    wire signed [18:0] t1s = t1 >>> 12;
    wire signed [18:0] t2s = t2 >>> 12;
    always @(posedge clk) begin
        n_v    <= m_v;
        n_px   <= m_px;
        n_prod <= m_prod;
        cu     <= -(t1s * $signed({1'b0, gc}));
        cv     <= t2s * $signed({1'b0, gc});
    end

    // Stage 3: clamp, core, average with the line above, write.
    // C is averaged with the same pixel of the previous field line (same
    // U / V phase). Luma leaking into chroma (cross-colour on sharp edges)
    // flips sign from line to line in NTSC and cancels; chroma noise drops
    // by ~3 dB; vertical colour resolution halves.
    wire signed [37:0] c_sel = n_px[0] ? cv : cu;
    wire signed [17:0] c_sh  = c_sel >>> 20;
    wire signed [7:0]  c_cur = (c_sh > 18'sd127)  ?  8'sd127 :
                               (c_sh < -18'sd127) ? -8'sd127 :
                               (c_sh > -18'sd4 && c_sh < 18'sd4) ? 8'sd0 :   // coring
                               c_sh[7:0];
    reg  signed [7:0]  cprev [0:1023];
    reg  signed [7:0]  c_up;
    wire signed [8:0]  c_sum = c_cur + c_up;
    always @(posedge clk) begin
        c_up <= cprev[m_px];                  // read for the pixel entering stage 3
        if (n_v) cprev[n_px] <= c_cur;
    end
    always @(posedge clk) begin
        we <= n_v;
        if (n_v) begin
            waddr <= {idx_n[4:0], 9'd0} + {2'd0, idx_n[4:0], 7'd0} + {5'd0, n_px};   // slot * 640 + px
            if (n_prod < 0)                    wdata[15:8] <= 8'd0;
            else if (n_prod[28:12] > 17'd255)  wdata[15:8] <= 8'd255;
            else                               wdata[15:8] <= n_prod[19:12];
            wdata[7:0] <= (idx_n == 10'd0) ? c_cur : c_sum[8:1];
        end
    end

    // Event counts per 2^26 clocks (0.795 s) for the status packet.
    reg [25:0] st_win;
    reg [15:0] h_cnt, b_cnt, f_cnt, ln_cnt, p1_cnt, v_cnt;
    reg [15:0] h_ps, b_ps, f_ps, ln_ps, p1_ps, v_ps;
    wire       par_new = vs_par;
    always @(posedge clk) begin
        st_win <= st_win + 26'd1;
        if (&st_win) begin
            h_ps <= h_cnt; b_ps <= b_cnt; f_ps <= f_cnt; ln_ps <= ln_cnt; p1_ps <= p1_cnt; v_ps <= v_cnt;
            h_cnt <= 0; b_cnt <= 0; f_cnt <= 0; ln_cnt <= 0; p1_cnt <= 0; v_cnt <= 0;
        end else begin
            if (is_h)              h_cnt  <= h_cnt + 16'd1;
            if (fs_synth)          b_cnt  <= b_cnt + 16'd1;   // fields synthesised
            if (vs_ev)             v_cnt  <= v_cnt + 16'd1;   // vertical sync detections
            if (fs_real)           f_cnt  <= f_cnt + 16'd1;
            if (fs_real && par_new) p1_cnt <= p1_cnt + 16'd1;  // second fields
            if (n_v)               ln_cnt <= ln_cnt + 16'd1;   // pixels written
        end
    end
    assign status = {
        gc[17:2],                           // 255:240
        c_dbg[31:16], c_dbg[47:32],         // 239:208  |R|, NCO offset
        c_dbg[15:0], f_ps, b_ps, h_ps,      // 207:144  last |B|/16
        {3'd0, gain}, v_ps,                 // 143:112  (v_ps: vertical sync detections)
        {2'd0, thr}, {2'd0, black_f}, {2'd0, tip_f}, jumps,           // 111:48
        {p1_ps[10:0], lvl_n}, {6'd0, n},    // 47:16  (fields with parity 1 | lvl_n)
        real_lines                          // 15:0
    };

    always @(posedge clk) begin
        if (rst) field_tg <= 1'b0;
        // after active line 2: the display reads one line ahead to interpolate
        else if (n_v && idx_n == 10'd2 && n_px == 10'd639) field_tg <= ~field_tg;
    end
endmodule
