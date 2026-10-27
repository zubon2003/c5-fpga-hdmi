// Asynchronous receiver for one C5VRX 6-bit CVBS bus.
//
// C5VRX drives its 6 DAC pins from PARLIO TX at 40 MHz with every sample
// repeated twice, so a new 20 MS/s sample appears every 50 ns and there is no
// clock pin.  The bus is oversampled at clk_os (150 MHz, 7.5x).  A phase
// accumulator runs at the nominal 20 MHz symbol rate; every observed bus
// transition pulls its phase towards the symbol boundary, and the bus is
// sampled half a symbol later, away from the bit-to-bit skew at the edges.
//
// The recovered samples cross into clk_sys through a two-entry ping-pong
// register and a toggle: an entry is not overwritten until two symbols
// (>= 93 ns) after it was published, which is far longer than the
// synchroniser delay in clk_sys (75 MHz).
module cvbs_os_rx #(
    parameter [15:0] INC = 16'd8738        // 65536 * 20 MHz / 150 MHz
) (
    input  wire       clk_os,
    input  wire       rst_os,
    input  wire [5:0] pin,

    input  wire       clk_sys,
    input  wire       rst_sys,
    output reg        s_valid,
    output reg  [5:0] s_data
);

    // ---------------- clk_os domain ----------------
    (* syn_keep = 1 *) reg [5:0] m0;
    reg [5:0] m1, m2;
    always @(posedge clk_os) begin
        m0 <= pin;
        m1 <= m0;
        m2 <= m1;
    end

    // The loop is pipelined so that every clk_os path has at most one adder:
    //   cycle n   : transition seen, phase error e = acc - INC/2 registered
    //   cycle n+1 : step for the accumulator = INC - e/4 registered
    //   cycle n+2 : accumulator advanced with the corrected step
    // Transitions are at least ~7 clocks apart, so the two-cycle delay does not
    // matter to the loop.
    //
    // The bus changed somewhere between the m2 and m1 samples, i.e. on average
    // half an oversampling period before the current phase.  That instant
    // should be the symbol boundary (phase 0), so the residual is the error.
    reg  [15:0] acc;
    reg  [15:0] err_r;
    reg         trans_r;
    reg  [15:0] step;
    reg         msb_d;
    wire signed [15:0] err_s = err_r;
    // the bus is sampled when the phase crosses half a symbol; that crossing is
    // seen one clock late, so the sample is taken from m2 (= m1 a clock ago)
    wire        sample_now = acc[15] && !msb_d;

    reg  [5:0] hold0, hold1;
    reg        wsel, tog;
    always @(posedge clk_os) begin
        if (rst_os) begin
            acc     <= 16'd0;
            err_r   <= 16'd0;
            trans_r <= 1'b0;
            step    <= INC;
            msb_d   <= 1'b0;
            wsel    <= 1'b0;
            tog     <= 1'b0;
        end else begin
            trans_r <= (m1 != m2);
            err_r   <= acc - (INC >> 1);
            step    <= trans_r ? INC - {{2{err_s[15]}}, err_s[15:2]} : INC;   // err/4
            acc     <= acc + step;
            msb_d   <= acc[15];
            if (sample_now) begin
                if (wsel) hold1 <= m2; else hold0 <= m2;
                wsel <= ~wsel;
                tog  <= ~tog;
            end
        end
    end

    // ---------------- clk_sys domain ----------------
    // wsel and tog flip together, so the entry written at a toggle is the one
    // selected by the old toggle value, i.e. ~new value.
    reg t1, t2, t3;
    always @(posedge clk_sys) begin
        t1 <= tog;
        t2 <= t1;
        t3 <= t2;
        s_valid <= 1'b0;
        if (!rst_sys && t2 != t3) begin
            s_data  <= t2 ? hold0 : hold1;
            s_valid <= 1'b1;
        end
    end

endmodule
