// Telemetry receiver for one XIAO (C5VRX "tang link", see design/iq_link.md).
//
// The XIAO sends an 8-byte packet on a UART line (2 Mbaud 8N1, idle high)
// after every gain write and at least every 2 ms:
//   0  0xC5        sync
//   1  seq         +1 per packet
//   2  gain        vendor gain-table index the receiver is using now
//   3  flags       [1:0] IQ lane (0 coarse, 1 fine, 2 ultrafine)
//                  [2] carrier present  [3] AFC locked  [4] video detected
//                  [5] PAL  [7:6] 0
//   4  channel     0..47 (R1..R8, A1..A8, B, E, F, L)
//   5  offset      AFC frequency offset, signed, 25 kHz per LSB
//   6  reserved    0
//   7  check       bytes 0..7 sum to 0 (mod 256)
//
// BIT_X2 is the bit time in half clocks (75 MHz / 2 Mbaud = 37.5 clocks).
module link_rx #(
    parameter [7:0]  BIT_X2  = 8'd75,
    parameter [21:0] TIMEOUT = 22'd1_500_000      // 20 ms at 75 MHz
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rxd,

    output reg         pkt_valid,     // pulse: a good packet arrived
    output reg  [7:0]  gain,
    output reg  [7:0]  flags,
    output reg  [7:0]  channel,
    output reg  signed [7:0] offset,
    output reg         link_ok,       // a good packet within TIMEOUT
    output wire        no_carrier,    // link up and the receiver reports no carrier
    output reg  [15:0] bad_pkts
);

    // ---------------- UART byte receiver ----------------
    reg [2:0]  rs;
    always @(posedge clk) rs <= {rs[1:0], rxd};
    wire rx = rs[2];

    reg        busy;
    reg [10:0] pc;          // half clocks since the start edge
    reg [10:0] tgt;
    reg [3:0]  nbit;
    reg [7:0]  sh;
    reg        b_valid;
    reg [7:0]  b_data;
    reg        rx_d;
    always @(posedge clk) begin
        b_valid <= 1'b0;
        rx_d    <= rx;
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy) begin
            if (rx_d && !rx) begin
                busy <= 1'b1;
                pc   <= 11'd2;
                tgt  <= {3'd0, BIT_X2} + {4'd0, BIT_X2[7:1]};   // middle of bit 0
                nbit <= 4'd0;
            end
        end else begin
            pc <= pc + 11'd2;
            if (pc >= tgt) begin
                tgt <= tgt + {3'd0, BIT_X2};
                if (nbit == 4'd8) begin
                    busy <= 1'b0;
                    if (rx) begin                  // stop bit
                        b_valid <= 1'b1;
                        b_data  <= sh;
                    end
                end else begin
                    sh   <= {rx, sh[7:1]};
                    nbit <= nbit + 4'd1;
                end
            end
        end
    end

    // ---------------- packet assembly ----------------
    reg [2:0]  idx;
    reg [7:0]  sum;
    reg [7:0]  p_gain, p_flags, p_chan, p_off;
    reg [11:0] gap;         // clocks since the last byte
    reg [21:0] age;
    always @(posedge clk) begin
        pkt_valid <= 1'b0;
        if (rst) begin
            idx <= 3'd0; gap <= 12'd0; age <= TIMEOUT; link_ok <= 1'b0;
            gain <= 8'd0; flags <= 8'd0; channel <= 8'd0; offset <= 8'sd0;
            bad_pkts <= 16'd0;
        end else begin
            if (age != TIMEOUT) age <= age + 22'd1;
            link_ok <= (age != TIMEOUT);
            if (gap != 12'hfff) gap <= gap + 12'd1;
            // more than ~5 byte times of silence: the next byte starts a packet
            if (gap == 12'd2000) idx <= 3'd0;
            if (b_valid) begin
                gap <= 12'd0;
                if (idx == 3'd0) begin
                    if (b_data == 8'hC5) begin idx <= 3'd1; sum <= 8'hC5; end
                end else begin
                    sum <= sum + b_data;
                    idx <= idx + 3'd1;
                    case (idx)
                        3'd2: p_gain  <= b_data;
                        3'd3: p_flags <= b_data;
                        3'd4: p_chan  <= b_data;
                        3'd5: p_off   <= b_data;
                        default: ;
                    endcase
                    if (idx == 3'd7) begin
                        idx <= 3'd0;
                        if (sum + b_data == 8'd0) begin
                            pkt_valid <= 1'b1;
                            age       <= 22'd0;
                            gain      <= p_gain;
                            flags     <= p_flags;
                            channel   <= p_chan;
                            offset    <= p_off;
                        end else if (bad_pkts != 16'hffff)
                            bad_pkts <= bad_pkts + 16'd1;
                    end
                end
            end
        end
    end

    assign no_carrier = link_ok && !flags[2];

endmodule
