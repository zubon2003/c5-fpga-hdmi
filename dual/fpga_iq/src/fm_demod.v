// FM discriminator for one C5VRX IQ stream (clk_os domain, 40 MS/s in,
// 20 MS/s out to clk_sys).
//
//   word --LUT--> phase (1024/turn) --diff--> dphi (40 MS/s)
//        --[1 3 3 1]--> /2 --> 20 MS/s frequency sample (unit: 40 MHz / 8192)
//
//  - The 4-bit I/Q cells are converted with their centres (iq_phase_lut).
//  - A phase step that starts or ends in one of the four origin cells is mostly
//    noise (FM threshold clicks); it is given half weight, as in C5VRX-5 U85Q.
//  - The binomial low-pass keeps the video band (-3 dB ~6.5 MHz at 40 MS/s)
//    and removes the alias band before the 2:1 decimation.
//  - Output: d = signed frequency, 1 LSB = 40 MHz / 8192 = 4.883 kHz
//    (+-20 MHz full range in 13 bits), plus the number of origin hits (0..2)
//    in the two words behind the sample, for the quality metric.
//
// The 20 MS/s samples cross to clk_sys with the same ping-pong + toggle as the
// v1 CVBS receiver (an entry is held for two samples, >= 93 ns).
module fm_demod (
    input  wire        clk_os,
    input  wire        rst_os,
    input  wire        w_valid,
    input  wire [7:0]  w_data,

    input  wire        clk_sys,
    input  wire        rst_sys,
    output reg         s_valid,
    output reg  signed [12:0] s_freq,
    output reg  [1:0]  s_click
);

    // ---------------- stage 1: phase lookup ----------------
    wire [9:0] ph;
    wire [1:0] cls;
    iq_phase_lut u_lut (.clk(clk_os), .w(w_data), .phase(ph), .cls(cls));
    reg v1;
    always @(posedge clk_os) v1 <= w_valid & ~rst_os;

    // ---------------- stage 2: phase difference ----------------
    reg  [9:0] ph_prev;
    reg        org_prev;
    reg        v2;
    reg signed [9:0] dphi;
    reg        org2;
    wire signed [9:0] dw = ph - ph_prev;           // wraps to -512..511
    always @(posedge clk_os) begin
        v2 <= 1'b0;
        if (rst_os) begin
            ph_prev  <= 10'd0;
            org_prev <= 1'b0;
        end else if (v1) begin
            ph_prev  <= ph;
            org_prev <= cls[0];
            v2       <= 1'b1;
            org2     <= cls[0];
            dphi     <= (cls[0] | org_prev) ? (dw >>> 1) : dw;
        end
    end

    // ---------------- stage 3: [1 3 3 1] low-pass ----------------
    // one adder per clk_os path: (d0 + d3), (d1 + d2) -> 3*(d1 + d2) -> sum
    reg signed [9:0]  d1, d2, d3;
    reg signed [10:0] sa, sb, sa2;
    reg signed [12:0] sb3;
    reg               v3, v3b, v4;
    reg signed [12:0] y;
    reg               org_d;
    reg [1:0]         clk3;
    always @(posedge clk_os) begin
        v3  <= 1'b0;
        v3b <= 1'b0;
        v4  <= 1'b0;
        if (rst_os) begin
            d1 <= 10'sd0; d2 <= 10'sd0; d3 <= 10'sd0;
        end else begin
            if (v2) begin
                d1 <= dphi; d2 <= d1; d3 <= d2;
                sa <= dphi + d3;
                sb <= d1 + d2;
                clk3  <= {1'b0, org2} + {1'b0, org_d};
                org_d <= org2;
                v3 <= 1'b1;
            end
            if (v3) begin
                sb3 <= sb + (sb <<< 1);
                sa2 <= sa;
                v3b <= 1'b1;
            end
            if (v3b) begin
                y  <= sa2 + sb3;                 // 8 x dphi at DC
                v4 <= 1'b1;
            end
        end
    end

    // ---------------- stage 4: 2:1 decimation + clock crossing ----------------
    reg        phase2;
    reg signed [12:0] hold0, hold1;
    reg [1:0]  hc0, hc1;
    reg        wsel, tog;
    always @(posedge clk_os) begin
        if (rst_os) begin
            phase2 <= 1'b0;
            wsel   <= 1'b0;
            tog    <= 1'b0;
        end else if (v4) begin
            phase2 <= ~phase2;
            if (phase2) begin
                if (wsel) begin hold1 <= y; hc1 <= clk3; end
                else      begin hold0 <= y; hc0 <= clk3; end
                wsel <= ~wsel;
                tog  <= ~tog;
            end
        end
    end

    reg t1, t2, t3;
    always @(posedge clk_sys) begin
        t1 <= tog;
        t2 <= t1;
        t3 <= t2;
        s_valid <= 1'b0;
        if (!rst_sys && t2 != t3) begin
            s_freq  <= t2 ? hold0 : hold1;
            s_click <= t2 ? hc0 : hc1;
            s_valid <= 1'b1;
        end
    end

endmodule
