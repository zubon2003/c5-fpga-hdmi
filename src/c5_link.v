// UART link to the receiver (C5VRX-5 UART build, see README): the Dock's
// user buttons step the band and the channel, and the receiver's channel
// reports are kept for the status packet (and later an on-screen display).
//
// Wire: 115200 8N1. FPGA TX -> XIAO D5 (C5 GPIO24), XIAO D4 (GPIO23) ->
// FPGA RX. Keys sent: 'b' next band (KEY0, H11), 'c' next channel (KEY1,
// H10), one per press; '?' once after power-up for an immediate report.
// The receiver answers "CH <name> <MHz>" plus CR LF on every change and
// once a second.
//
// Buttons: pull-down, pressed = high in public Dock constraints; the level
// each one rests at is still learned 0.1 s after reset and a press is the
// other level (20 ms debounce).
module c5_link #(
    parameter CLK_HZ = 84375000,
    parameter BAUD   = 115200
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  btn,           // [0] band, [1] channel
    input  wire        rxd,
    output wire        txd,
    output reg  [15:0] ch_name,       // two ASCII characters, e.g. "F3"
    output reg  [15:0] ch_mhz,        // binary MHz, 0 = no report yet
    output reg  [7:0]  reports,       // reports received (wraps)
    output reg  [7:0]  rx_edges,      // last byte received, for wiring checks
    output reg  [7:0]  rx_bytes       // bytes received (wraps)
);
    localparam DIV    = CLK_HZ / BAUD;
    localparam MS     = CLK_HZ / 1000;
    localparam [31:0] T_IDLE = 100 * MS;   // learn the resting levels
    localparam [31:0] T_DEB  = 20 * MS;

    // ---- keys out ----
    reg        tx_valid;
    reg  [7:0] tx_data;
    wire       tx_ready;
    uart_tx #(.DIV(DIV)) u_tx (.clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data),
                               .ready(tx_ready), .txd(txd));

    reg [2:0]  bs0, bs1;                    // synchronisers
    reg [1:0]  rest, pressed, pend;         // pend: a press waiting for the transmitter
    reg        learned, hello;
    reg [31:0] t, deb0, deb1;
    wire [1:0] raw = {bs1[2], bs0[2]} ^ rest;   // 1 while pressed
    always @(posedge clk) begin
        bs0      <= {bs0[1:0], btn[0]};
        bs1      <= {bs1[1:0], btn[1]};
        tx_valid <= 1'b0;
        if (rst) begin
            t <= 0; learned <= 1'b0; hello <= 1'b0;
            pressed <= 2'b00; pend <= 2'b00; deb0 <= 0; deb1 <= 0;
        end else if (!learned) begin
            if (t == T_IDLE) begin rest <= {bs1[2], bs0[2]}; learned <= 1'b1; end
            else t <= t + 32'd1;
        end else begin
            // debounce: a level must hold T_DEB before it counts
            if (raw[0] == pressed[0]) deb0 <= 0;
            else if (deb0 == T_DEB) begin
                deb0 <= 0; pressed[0] <= raw[0];
                if (raw[0]) pend[0] <= 1'b1;
            end else deb0 <= deb0 + 32'd1;
            if (raw[1] == pressed[1]) deb1 <= 0;
            else if (deb1 == T_DEB) begin
                deb1 <= 0; pressed[1] <= raw[1];
                if (raw[1]) pend[1] <= 1'b1;
            end else deb1 <= deb1 + 32'd1;
            if (tx_ready && !tx_valid) begin
                if (!hello)       begin tx_data <= "?"; tx_valid <= 1'b1; hello   <= 1'b1; end
                else if (pend[0]) begin tx_data <= "b"; tx_valid <= 1'b1; pend[0] <= 1'b0; end
                else if (pend[1]) begin tx_data <= "c"; tx_valid <= 1'b1; pend[1] <= 1'b0; end
            end
        end
    end

    // ---- reports in: "CH <name> <MHz>\r\n" ----
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.DIV(DIV)) u_rx (.clk(clk), .rst(rst), .rxd(rxd), .valid(rx_valid), .data(rx_data));

    reg [2:0] rs = 3'b111;
    always @(posedge clk) begin
        rs <= {rs[1:0], rxd};
        if (rst) begin
            rx_edges <= 0; rx_bytes <= 0;
        end else begin
            if (rx_valid) begin
                rx_edges <= rx_data;
                rx_bytes <= rx_bytes + 8'd1;
            end
        end
    end

    localparam S_C = 3'd0, S_H = 3'd1, S_SP1 = 3'd2, S_NAME = 3'd3, S_MHZ = 3'd4;
    reg [2:0]  s;
    reg [15:0] name, mhz;
    reg [1:0]  nn;
    wire       digit = rx_data >= "0" && rx_data <= "9";
    always @(posedge clk) begin
        if (rst) begin
            s <= S_C; ch_name <= "--"; ch_mhz <= 0; reports <= 0;
        end else if (rx_valid) begin
            case (s)
                S_C:    s <= (rx_data == "C") ? S_H : S_C;
                S_H:    s <= (rx_data == "H") ? S_SP1 : S_C;
                S_SP1:  begin s <= (rx_data == " ") ? S_NAME : S_C; nn <= 0; name <= 0; end
                S_NAME: if (rx_data == " ") begin
                            s <= (nn != 0) ? S_MHZ : S_C; mhz <= 0;
                        end else if (nn == 2'd2) s <= S_C;       // names are two characters
                        else begin name <= {name[7:0], rx_data}; nn <= nn + 2'd1; end
                S_MHZ:  if (digit) mhz <= mhz * 16'd10 + {12'd0, rx_data[3:0]};
                        else begin
                            // CR or LF ("\r" is not a Verilog-2001 escape: Gowin
                            // read it as another character and dropped every report)
                            if (rx_data == 8'h0d || rx_data == 8'h0a) begin
                                ch_name <= name; ch_mhz <= mhz; reports <= reports + 8'd1;
                            end
                            s <= S_C;
                        end
                default: s <= S_C;
            endcase
        end
    end
endmodule
