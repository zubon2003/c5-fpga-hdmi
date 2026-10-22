// FM demodulator on the resampled IQ symbols (~80 MS/s, valid-qualified).
//
// mode 0, adjacent discriminator (the original):
//   phase = LUT(I4, Q4), 1024 units per turn; d = phase - previous phase.
// mode 1..3, amplitude-gated phase-locked loop (power-up mode 1, top.v):
//   theta and omega in 1/65536 turn; e = phase - (theta + omega) wrapped;
//   the correction gain g (0, 1/4, 1/2, 3/4, 1) is |z|^2 of the symbol's
//   cell against its slow average, so symbols near the origin (whose phase
//   is mostly noise with 4-bit IQ) barely move the loop;
//   theta += omega + g kp e, omega += g ki e, output omega + g kp e.
//   mode 1: kp 3/8, ki 1/32 (fast: sharpest on strong signals; walk test
//           2026-10-22: mode 2 held sync at 2 dB C/N where mode 0 lost it,
//           and both PLL modes beat mode 0's video SNR close in)
//   mode 2: kp 1/4, ki 1/64
//   mode 3: kp 1/8, ki 1/128 (slow: holds sync longest, softer picture)
//   Host simulation (research/demod_sim.py, NTSC, deviation 0.69..1.4):
//   mode 2 keeps H sync in 90 % of the lines 3.4..4.2 dB lower in C/N
//   than mode 0 and needs ~1 dB less C/N for 10 dB luma SINAD; a wide VTX
//   (deviation 1.4) loses ~3 dB of SINAD close in, where mode 1 is better.
//   The loop runs every symbol whatever the mode, so switching is seamless.
//   A correction applied one or two symbols late cost ~3 dB of SINAD in
//   the simulation, so theta and omega update in a single clock.
//   The tracker-gain idea extends the C5VRX-5 U85Q tracker and its kp
//   ladder (C5VRX by Twotoz and the C5VRX contributors); the amplitude
//   gate and the second-order loop are new here.
// The selected phase step goes through a 22-sample boxcar (first null at
// 80 / 22 = 3.64 MHz, which keeps most of the 3.58 MHz colour subcarrier
// out of luma). One unit of vid is 80 MHz / 1024 / 22 = 3.551 kHz of
// instantaneous frequency in every mode; 1 MHz = 281.6. The chroma path
// always gets the adjacent d (d_out), since the loop low-passes the
// subcarrier. Latency: 4 valid symbols. sym_out is the symbol whose step
// entered vid this clock (mode B capture check, bit-exact in mode 0).
// Bit-level model: scripts/fm_model.py (mode 0), research/demod_sim.py.
module fm_demod (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire [7:0]         sym,
    input  wire [1:0]         mode,
    output reg                out_valid,
    output reg signed [13:0]  vid,
    output reg [7:0]          sym_out,
    output reg signed [9:0]   d_out
);
    localparam N = 22;
`include "phase_lut.vh"

    // 4 |z|^2 of the cell centre: (2I + 1)^2 + (2Q + 1)^2, 2..450.
    function [8:0] pow4;
        input [7:0] b;
        reg signed [4:0] i2, q2;
        reg [9:0] r;
        begin
            i2 = {b[7:4], 1'b1};
            q2 = {b[3:0], 1'b1};
            r = i2 * i2 + q2 * q2;
            pow4 = r[8:0];
        end
    endfunction

    reg               v1, v2, v3;
    // stage 1: phase and power
    reg [9:0]         ph1, ph_prev;
    reg [8:0]         p1;
    reg [7:0]         sym1, sym2, sym3;
    reg [20:0]        avg;             // slow average of the power, * 4096
    reg [8:0]         mean;
    // stage 2: gain code and adjacent step
    reg [9:0]         ph2;
    reg [2:0]         gc2;
    reg signed [9:0]  d2, d3;
    // the loop
    reg [15:0]        s;               // theta + omega: the next prediction
    reg signed [15:0] om;
    reg signed [15:0] step3;
    // boxcar
    reg [16*N-1:0]    hist /* synthesis syn_srlstyle = "registers" */;   // the last N steps, newest low
    reg signed [20:0] acc;

    wire signed [15:0] e = $signed({ph2, 6'd0} - s);
    reg  signed [15:0] ge, corr, inc;
    always @* begin
        case (gc2)
            3'd4:    ge = e;
            3'd3:    ge = (e >>> 1) + (e >>> 2);
            3'd2:    ge = e >>> 1;
            3'd1:    ge = e >>> 2;
            default: ge = 16'sd0;
        endcase
        case (mode)
            2'd1:    begin corr = (ge >>> 2) + (ge >>> 3); inc = ge >>> 5; end
            2'd3:    begin corr = ge >>> 3;                inc = ge >>> 7; end
            default: begin corr = ge >>> 2;                inc = ge >>> 6; end
        endcase
    end

    wire signed [15:0] step_in  = (mode == 2'd0) ? {d3, 6'd0} : step3;
    wire signed [15:0] oldest   = hist[16*N-1 -: 16];
    wire signed [20:0] acc_next = acc + step_in - oldest;
    wire [10:0] p4 = {p1, 2'd0};
    wire [10:0] m1 = {2'd0, mean};
    wire [10:0] m3 = {1'b0, mean, 1'b0} + {2'd0, mean};

    always @(posedge clk) begin
        v1 <= in_valid;
        v2 <= v1;
        v3 <= v2;
        out_valid <= 1'b0;
        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            ph_prev <= 10'd0;
            avg  <= 21'd262144;         // mean 64
            mean <= 9'd64;
            s <= 16'd0; om <= 16'sd0;
            acc <= 21'sd0;
            vid <= 14'sd0;
            hist <= 0;
        end else begin
            if (in_valid) begin
                ph1  <= phase_lut(sym);
                p1   <= pow4(sym);
                sym1 <= sym;
            end
            if (v1) begin
                avg  <= avg + {12'd0, p1} - {12'd0, avg[20:12]};
                mean <= avg[20:12];
                gc2  <= ({2'd0, p1} >= m1)       ? 3'd4 :    // |z|^2 >= mean
                        (p4 >= m3)               ? 3'd3 :    // >= 3/4
                        ({1'b0, p1, 1'b0} >= m1) ? 3'd2 :    // >= 1/2
                        (p4 >= m1)               ? 3'd1 :    // >= 1/4
                                                   3'd0;
                ph2  <= ph1;
                d2   <= ph1 - ph_prev;
                ph_prev <= ph1;
                sym2 <= sym1;
            end
            if (v2) begin
                s     <= s + om + corr + inc;
                om    <= om + inc;
                step3 <= om + corr;
                d3    <= d2;
                sym3  <= sym2;
            end
            if (v3) begin
                hist <= {hist[16*N-17:0], step_in};
                acc       <= acc_next;
                vid       <= acc_next[19:6];
                sym_out   <= sym3;
                d_out     <= d3;
                out_valid <= 1'b1;
            end
        end
    end
endmodule
