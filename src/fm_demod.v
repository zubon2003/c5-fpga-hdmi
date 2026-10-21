// FM discriminator on the resampled IQ symbols (~80 MS/s, valid-qualified):
//   phase = LUT(I4, Q4), 1024 units per turn
//   d     = phase - previous phase, wrapped to signed 10 bits
//   vid   = sum of the last 16 d (boxcar, first null at 80 / 16 = 5 MHz)
// One unit of vid is 80 MHz / 1024 / 16 = 4.883 kHz of instantaneous
// frequency; 1 MHz = 204.8. Latency: 3 valid symbols. sym_out is the
// symbol whose d entered vid this clock (for the mode B capture check).
// Bit-level model: scripts/fm_model.py.
module fm_demod (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire [7:0]         sym,
    output reg                out_valid,
    output reg signed [13:0]  vid,
    output reg [7:0]          sym_out
);
`include "phase_lut.vh"

    reg [9:0]         ph, ph_prev;
    reg [7:0]         sym1, sym2;
    reg               v1, v2;
    reg signed [9:0]  d;
    reg signed [9:0]  hist [0:15];
    integer k;

    always @(posedge clk) begin
        v1 <= in_valid;
        v2 <= 1'b0;
        out_valid <= 1'b0;
        if (rst) begin
            ph_prev <= 10'd0;
            vid     <= 14'sd0;
            v1      <= 1'b0;
            for (k = 0; k < 16; k = k + 1) hist[k] <= 10'sd0;
        end else begin
            if (in_valid) begin
                ph   <= phase_lut(sym);
                sym1 <= sym;
            end
            if (v1) begin
                d       <= ph - ph_prev;
                sym2    <= sym1;
                ph_prev <= ph;
                v2      <= 1'b1;
            end
            if (v2) begin
                hist[0] <= d;
                for (k = 1; k < 16; k = k + 1) hist[k] <= hist[k-1];
                vid       <= vid + d - hist[15];
                sym_out   <= sym2;
                out_valid <= 1'b1;
            end
        end
    end
endmodule
