// Asynchronous receiver for one C5VRX IQ bus (8 bits, 40 MS/s, no clock pin).
//
// The XIAO streams its ADC through MODEM_DIAG onto 8 GPIOs at 40 MS/s: a new
// IQ word every 25 ns, launched from the ESP32-C5's own 40 MHz.  The bus is
// oversampled at clk_os (150 MHz, 3.75x).  A phase accumulator runs at the
// nominal 40 MHz word rate; every observed bus change pulls its phase towards
// the word boundary, and the bus is taken half a word later, i.e. at least
// ~9 ns away from either edge, which leaves room for the bit-to-bit skew of
// the GPIO pads and the Pmod wiring.
//
// Same loop as cvbs_os_rx (pipelined so that each clk_os path has one adder),
// with a smaller correction (err/16): changes are only ~3.75 clocks apart
// here, so a second correction can be computed before the first has landed.
// That only raises the loop gain a little.
//
// Output: one strobe per word in the clk_os domain.
module iq_os_rx #(
    parameter [15:0] INC = 16'd17476       // 65536 * 40 MHz / 150 MHz
) (
    input  wire       clk_os,
    input  wire       rst_os,
    input  wire [7:0] pin,
    output reg        w_valid,
    output reg  [7:0] w_data,
    output reg        lock                  // changes seen recently
);

    (* syn_keep = 1 *) reg [7:0] m0;
    reg [7:0] m1, m2;
    always @(posedge clk_os) begin
        m0 <= pin;
        m1 <= m0;
        m2 <= m1;
    end

    reg  [15:0] acc;
    reg  [15:0] err_r;
    reg         trans_r;
    reg  [15:0] step;
    reg         msb_d;
    reg  [9:0]  quiet;
    wire signed [15:0] err_s = err_r;
    wire        sample_now = acc[15] && !msb_d;

    always @(posedge clk_os) begin
        w_valid <= 1'b0;
        if (rst_os) begin
            acc     <= 16'd0;
            err_r   <= 16'd0;
            trans_r <= 1'b0;
            step    <= INC;
            msb_d   <= 1'b0;
            quiet   <= 10'h3ff;
            lock    <= 1'b0;
        end else begin
            trans_r <= (m1 != m2);
            err_r   <= acc - (INC >> 1);
            step    <= trans_r ? INC - {{4{err_s[15]}}, err_s[15:4]} : INC;   // err/16
            acc     <= acc + step;
            msb_d   <= acc[15];
            if (sample_now) begin
                w_valid <= 1'b1;
                w_data  <= m2;
            end
            // a live IQ stream changes every few words; ~7 us without a change
            // means the XIAO is off or not streaming
            if (trans_r) quiet <= 10'd0;
            else if (quiet != 10'h3ff) quiet <= quiet + 10'd1;
            lock <= (quiet != 10'h3ff);
        end
    end

endmodule
