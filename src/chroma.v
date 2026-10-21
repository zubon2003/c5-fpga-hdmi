// NTSC colour: subcarrier mixing and per-line burst reference
// (IQ domain, valid-qualified samples at ~80 MS/s).
//
// The raw discriminator output d (no low-pass) is mixed with a free-running
// 3.579545 MHz NCO: pc = d cos, ps = -d sin (>> 4). Mc / Ms are 128-sample
// moving sums of pc / ps (1.6 us: the chroma low-pass, which also pushes
// the luma that the mixing moved up to 3.58 MHz out). 64 samples left
// visible colour noise on the board; FM noise rises with frequency.
//
// Burst: during burst_gate (160 samples on the back porch of a real line)
// pc / ps are summed into B = Bc + j Bs. After the gate the line's
// reference is computed sequentially (a few hundred clocks, done long
// before the picture starts):
//   mag ~ |R| (max + 0.375 min)
//   G   = 2^24 / mag
//   uc  = Rc G / 4096, us = Rs G / 4096   (unit burst vector, 4096 = 1)
//   gc  = G * 255 / 512                   (ACC: chroma relative to burst)
// The pixel stage then forms M conj(unit B) and scales it by gc, so a
// chroma amplitude equal to the burst comes out as 51 (20 IRE in 8-bit
// luma units, 100 IRE = 255). A burst below KILL turns colour off (gc = 0).
// Frequency lock: the burst phase relative to the free-running NCO drifted
// ~3 degrees per line on the board. Each line the sign of
// Im(B_n conj B_n-1) moves the NCO increment by one step, so the drift goes
// to zero (lock in a few hundred lines). The reference R is then an IIR
// average of B over ~8 lines (per-line burst noise gave line-to-line hue
// and saturation streaks), and uc / us / gc come from R. B is kept to
// 16 bits (>> 4) for this.
module chroma #(
    parameter [20:0] KILL = 21'd38,          // on |R|, i.e. |B| / 16
    parameter [31:0] LOCK_STEP = 32'd16      // NCO increment step per line
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [9:0]  d,
    input  wire               burst_gate,
    output reg  signed [15:0] mc,
    output reg  signed [15:0] ms,
    output reg  signed [13:0] uc,
    output reg  signed [13:0] us,
    output reg  [17:0]        gc,
    output wire [47:0]        dbg,           // {NCO increment - nominal, |R|, last |B| / 16}
    output wire               dbg_v,         // per mixed sample (for the UART 'G' capture):
    output wire [31:0]        dbg_w          // {pc[12:0], 2'b0, gate, d[9:0], 6'b0}
);
`include "sincos_lut.vh"

    reg [31:0] theta;
    reg [31:0] inc;
    reg signed [9:0] d1;
    reg signed [7:0] cs, sn;
    reg v1, v2;
    reg signed [12:0] pc, ps;
    // Full-width products: in "pc <= (d1 * cs) >>> 4" Verilog sizes the
    // product to pc's 13 bits and it overflows before the shift (seen on
    // the board as chroma that did not follow the subcarrier at all).
    wire signed [17:0] prod_c = d1 * cs;
    wire signed [17:0] prod_s = d1 * sn;

    always @(posedge clk) begin
        v1 <= in_valid;
        v2 <= v1;
        if (rst) theta <= 0;
        if (in_valid && !rst) begin
            theta <= theta + inc;
            cs    <= cos_lut(theta[31:24]);
            sn    <= sin_lut(theta[31:24]);
            d1    <= d;
        end
        if (v1) begin
            pc <= prod_c >>> 4;
            ps <= -(prod_s >>> 4);
        end
    end

    reg signed [9:0] d2;
    always @(posedge clk) if (v1) d2 <= d1;
    assign dbg_v = v2;
    assign dbg_w = {pc, 2'b00, burst_gate, d2, 6'd0};

    // 128-sample moving sums as integrator minus the integrator 128 samples
    // ago (wrapping arithmetic, exact while the sum fits 20 bits). The old
    // value is read from a 128-entry ring one write ahead, so read and write
    // never hit the same address in a clock; unknown RAM contents after
    // configuration only affect the first 128 samples.
    reg signed [20:0] ic, is_;
    reg signed [20:0] rc [0:127];
    reg signed [20:0] rs [0:127];
    reg [6:0]         wp;
    reg signed [20:0] oc, os;       // ring[wp], read ahead of its write
    reg signed [20:0] sc, ss;
    always @(posedge clk) begin
        if (rst) begin
            ic <= 0; is_ <= 0; wp <= 0;
        end else if (v2) begin
            ic     <= ic + pc;
            is_    <= is_ + ps;
            rc[wp] <= ic + pc;
            rs[wp] <= is_ + ps;
            sc     <= ic + pc - oc;
            ss     <= is_ + ps - os;
            wp     <= wp + 7'd1;
        end
        oc <= rc[v2 ? wp + 7'd1 : wp];   // the address of the next write
        os <= rs[v2 ? wp + 7'd1 : wp];
        // halved, so a full-burst-amplitude chroma reads as with 64 samples
        mc <= ((sc >>> 1) > 21'sd32767) ? 16'sd32767 : ((sc >>> 1) < -21'sd32767) ? -16'sd32767 : sc[16:1];
        ms <= ((ss >>> 1) > 21'sd32767) ? 16'sd32767 : ((ss >>> 1) < -21'sd32767) ? -16'sd32767 : ss[16:1];
    end

    // Burst sums.
    reg signed [20:0] bc, bs;
    reg gate_d;
    reg start;
    always @(posedge clk) begin
        gate_d <= burst_gate;
        start  <= gate_d && !burst_gate;
        if (burst_gate && !gate_d) begin
            bc <= 0; bs <= 0;
        end else if (burst_gate && v2) begin
            bc <= bc + pc;
            bs <= bs + ps;
        end
    end

    // Per-line reference, sequential.
    localparam F_IDLE = 4'd0, F_MAG = 4'd1, F_DIV = 4'd2, F_MULC = 4'd3, F_MULS = 4'd4,
               F_X1 = 4'd5, F_X2 = 4'd6, F_IIR = 4'd7, F_ABS = 4'd8;
    reg [3:0]  f;
    reg signed [15:0] b16c, b16s, pbc, pbs;        // this and the previous burst
    reg signed [31:0] x1, x2;
    reg               p_ok;                        // previous burst was strong
    reg signed [18:0] rcf, rsf;                    // R, 3 fraction bits
    wire signed [15:0] rc16 = rcf >>> 3;
    wire signed [15:0] rs16 = rsf >>> 3;
    function signed [15:0] sat16(input signed [20:0] x);
        sat16 = (x > 21'sd32767) ? 16'sd32767 : (x < -21'sd32767) ? -16'sd32767 : x[15:0];
    endfunction
    wire [15:0] b_abs_c = b16c[15] ? -b16c : b16c;
    wire [15:0] b_abs_s = b16s[15] ? -b16s : b16s;
    wire [15:0] b_mag   = (b_abs_c > b_abs_s) ? b_abs_c + (b_abs_s >> 2) : b_abs_s + (b_abs_c >> 2);
    wire signed [31:0] inc_off = inc - SC_INC;
    reg  [15:0] last_bmag;
    always @(posedge clk) if (f == F_X2) last_bmag <= b_mag;
    assign dbg = {(inc_off > 32'sd32767) ? 16'h7fff : (inc_off < -32'sd32767) ? 16'h8001 : inc_off[15:0],
                  mag[15:0], last_bmag};
    reg [20:0] ac, as_, mag;
    reg [24:0] rem, q;          // 2^24 / mag
    reg [4:0]  i;
    reg [18:0] g;
    reg signed [20:0] mul_a;
    reg [18:0] mul_b;
    reg signed [40:0] acc;
    reg signed [13:0] uc_n;

    function signed [13:0] sat14(input signed [40:0] x);
        sat14 = (x > 41'sd4095) ? 14'sd4095 : (x < -41'sd4095) ? -14'sd4095 : x[13:0];
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            f    <= F_IDLE;
            gc   <= 0;
            uc   <= 14'sd4096 - 14'sd1;
            us   <= 0;
            inc  <= SC_INC;
            p_ok <= 1'b0;
            rcf  <= 0;
            rsf  <= 0;
        end else case (f)
            F_IDLE: if (start) begin
                b16c <= sat16(bc >>> 4);
                b16s <= sat16(bs >>> 4);
                f    <= F_X1;
            end
            F_X1: begin
                x1 <= b16s * pbc;
                x2 <= b16c * pbs;
                f  <= F_X2;
            end
            F_X2: begin
                // frequency lock on Im(B_n conj B_n-1), strong bursts only
                if (p_ok && b_mag >= KILL[15:0]) begin
                    if (x1 > x2)      inc <= inc + LOCK_STEP;
                    else if (x1 < x2) inc <= inc - LOCK_STEP;
                end
                p_ok <= (b_mag >= KILL[15:0]);
                pbc  <= b16c;
                pbs  <= b16s;
                f    <= F_IIR;
            end
            F_IIR: begin
                if (b_mag >= KILL[15:0]) begin
                    // $signed: a plain concatenation is unsigned and made the
                    // difference and the shift unsigned (R ran away on the board)
                    rcf <= rcf + (($signed({b16c, 3'b000}) - rcf) >>> 3);
                    rsf <= rsf + (($signed({b16s, 3'b000}) - rsf) >>> 3);
                end
                f <= F_ABS;
            end
            F_ABS: begin
                ac  <= rc16[15] ? -{{5{rc16[15]}}, rc16} : {{5{rc16[15]}}, rc16};
                as_ <= rs16[15] ? -{{5{rs16[15]}}, rs16} : {{5{rs16[15]}}, rs16};
                f   <= F_MAG;
            end
            F_MAG: begin
                mag <= (ac > as_) ? ac + (as_ >> 2) + (as_ >> 3) : as_ + (ac >> 2) + (ac >> 3);
                rem <= 0;
                q   <= 25'h1000000;
                i   <= 5'd25;
                f   <= F_DIV;
            end
            F_DIV: if (i != 0) begin
                if ({rem[23:0], q[24]} >= {4'd0, mag}) begin
                    rem <= {rem[23:0], q[24]} - {4'd0, mag};
                    q   <= {q[23:0], 1'b1};
                end else begin
                    rem <= {rem[23:0], q[24]};
                    q   <= {q[23:0], 1'b0};
                end
                i <= i - 5'd1;
            end else begin
                g     <= (q > 25'h7ffff) ? 19'h7ffff : q[18:0];
                mul_a <= {{5{rc16[15]}}, rc16};
                mul_b <= (q > 25'h7ffff) ? 19'h7ffff : q[18:0];
                acc   <= 0;
                i     <= 5'd19;
                f     <= F_MULC;
            end
            F_MULC, F_MULS: if (i != 0) begin
                // acc = mul_a * mul_b, shift-add from the top bit of mul_b
                acc   <= (acc <<< 1) + (mul_b[18] ? {{20{mul_a[20]}}, mul_a} : 41'sd0);
                mul_b <= {mul_b[17:0], 1'b0};
                i     <= i - 5'd1;
            end else if (f == F_MULC) begin
                uc_n  <= sat14(acc >>> 12);
                mul_a <= {{5{rs16[15]}}, rs16};
                mul_b <= g;
                acc   <= 0;
                i     <= 5'd19;
                f     <= F_MULS;
            end else begin
                if (mag < KILL) begin
                    gc <= 0;
                end else begin
                    uc <= uc_n;
                    us <= sat14(acc >>> 12);
                    // G * 255 / 512: R is |B| / 16, so G is 16 times larger
                    gc <= ({g, 8'd0} - {8'd0, g}) >> 9 > 27'h3ffff ? 18'h3ffff : (({g, 8'd0} - {8'd0, g}) >> 9);
                end
                f <= F_IDLE;
            end
            default: f <= F_IDLE;
        endcase
    end
endmodule
