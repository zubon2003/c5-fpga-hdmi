// Phase-tracking resampler: 675 MS/s oversampled IQ bytes -> one IQ byte
// per symbol of the C5's ~80 MHz MODEM_DIAG bus (no clock is exported, and
// the C5 and Dock crystals differ by ~30 ppm).
//
// Each clock (84.375 MHz) brings 8 samples, byte j = sample j, oldest first.
// The symbol period is 675 / 80 = 8.4375 samples = 540 units of 1/64
// sample, longer than the 8-sample window, so at most one symbol leaves per
// clock. pos is the sample point inside the current window in 1/64 units.
//
// Phase detector (Alexander style, on whole bytes): E is the sample half a
// symbol before the sample point S. When the byte changed since the last
// symbol, E == S means the edge came before E (sample later than the eye
// centre: move earlier), E == previous symbol means it came after E (move
// later); a mixed E (pins mid-transition) does not vote. Eight net votes
// move pos by one unit (23 ps), far faster than the ~30 ppm drift needs.
// The samples are registered before the detector, and its step is applied
// at a later symbol, which keeps the detector out of the pos feedback path
// (timing at 84.375 MHz). The loop delay of two symbols does not matter
// against the ~0.016 units per symbol it has to follow.
module iq_resampler (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] win,          // 8 samples, byte 0 oldest
    output reg         sym_valid,
    output reg  [7:0]  sym,
    output reg  [15:0] early_cnt,    // votes per 2^16 clocks, for display
    output reg  [15:0] late_cnt
);
    localparam [9:0] STEP = 10'd28;  // 540 - 512

    reg  [63:0] prv;
    wire [127:0] buf16 = {win, prv};  // bytes 0..7 previous window, 8..15 current

    reg  [9:0] pos;
    reg  signed [4:0] acc;
    reg  [7:0] prev_sym;
    reg        corr_up, corr_dn;

    wire       here = (pos < 10'd512);
    wire [3:0] s_idx = {1'b1, pos[8:6]};
    wire [9:0] e_pos = pos + 10'd242;          // pos - 270 + 512
    wire [3:0] e_idx = e_pos[9:6];
    wire [7:0] s = buf16[s_idx * 8 +: 8];
    wire [7:0] e = buf16[e_idx * 8 +: 8];

    // Detector stage: the symbol emitted last clock and its edge sample.
    reg        h1;
    reg  [7:0] s1, e1;
    wire moved = (s1 != prev_sym);
    wire early = h1 && moved && (e1 == s1);
    wire late  = h1 && moved && !(e1 == s1) && (e1 == prev_sym);
    wire signed [4:0] acc_v = acc + (early ? -5'sd1 : late ? 5'sd1 : 5'sd0);
    wire step_up   = (acc_v == 5'sd8);
    wire step_down = (acc_v == -5'sd8);

    always @(posedge clk) begin
        prv       <= win;
        sym_valid <= 1'b0;
        h1        <= 1'b0;
        if (rst) begin
            pos      <= 10'd0;
            acc      <= 5'sd0;
            prev_sym <= 8'd0;
            corr_up  <= 1'b0;
            corr_dn  <= 1'b0;
        end else begin
            if (here) begin
                sym       <= s;
                sym_valid <= 1'b1;
                h1        <= 1'b1;
                s1        <= s;
                e1        <= e;
                pos       <= pos + STEP + {9'd0, corr_up} - {9'd0, corr_dn};
                corr_up   <= 1'b0;
                corr_dn   <= 1'b0;
            end else begin
                pos <= pos - 10'd512;
            end
            if (h1) begin
                prev_sym <= s1;
                acc      <= (step_up || step_down) ? 5'sd0 : acc_v;
                if (step_up)   corr_up <= 1'b1;
                if (step_down) corr_dn <= 1'b1;
            end
        end
    end

    reg [15:0] win_cnt, e_acc, l_acc;

    always @(posedge clk) begin
        win_cnt <= win_cnt + 16'd1;
        if (&win_cnt) begin
            early_cnt <= e_acc;
            late_cnt  <= l_acc;
            e_acc <= 0;
            l_acc <= 0;
        end else if (!rst) begin
            e_acc <= e_acc + (early ? 16'd1 : 16'd0);
            l_acc <= l_acc + (late ? 16'd1 : 16'd0);
        end
    end
endmodule
