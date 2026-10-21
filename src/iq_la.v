// IQ logic analyser in the 84.375 MHz domain.
//
// UART commands:
//   'C'  raw: 8192 clocks of 8 samples (65536 samples at 675 MS/s, 97 us)
//   'S'  symbols: 65536 resampler outputs (~80 MS/s, 819 us)
//   'B'  both: 16384 demodulator outputs as 32-bit words, bits 7..0 the IQ
//        byte and bits 31..16 the signed vid it produced (205 us)
// Reply: "IQL", the mode letter, the byte count (u32 LE), then the bytes in
// time order. Bytes are spaced GAP clocks apart: the Dock's BL616 USB-UART
// bridge forwards only ~27 kB/s and silently drops the rest of a 1 Mbaud
// burst (measured 2026-10-21: 27564 of 65536 bytes arrived).
//
// It also counts per-pin transitions over 2^20 clocks (12.4 ms) for the
// HDMI activity bars.
module iq_la #(
    parameter DEPTH_LOG2 = 13,         // 64-bit words
    parameter GAP        = 4219        // 50 us at 84.375 MHz -> ~16.7 kB/s
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [63:0]  win,           // 8 samples, byte 0 oldest
    input  wire         sym_valid,
    input  wire [7:0]   sym,
    input  wire         fm_valid,
    input  wire [13:0]  fm_vid,
    input  wire [7:0]   fm_sym,
    input  wire         rx_valid,
    input  wire [7:0]   rx_data,
    output reg          tx_valid,
    output reg  [7:0]   tx_data,
    input  wire         tx_ready,
    output wire         busy,
    output reg  [175:0] activity        // 8 x 22-bit transition counts
);
    localparam DEPTH = 1 << DEPTH_LOG2;
    localparam [31:0] BYTES = DEPTH * 8;

    reg [63:0] mem [0:DEPTH-1];
    reg [DEPTH_LOG2-1:0] waddr, raddr;
    reg [63:0] rdata, wdata;
    reg        wen;

    localparam S_IDLE = 3'd0, S_CAP = 3'd1, S_HDR = 3'd2, S_RD = 3'd3, S_SEND = 3'd4;
    reg [2:0] state;
    reg [1:0] mode;          // 0 raw, 1 symbols, 2 both
    reg [2:0] idx;           // header byte or byte within a word
    reg [1:0] wait_cnt;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (wen) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

    function [7:0] hdr_byte(input [2:0] i, input [1:0] m);
        case (i)
            3'd0: hdr_byte = "I";
            3'd1: hdr_byte = "Q";
            3'd2: hdr_byte = "L";
            3'd3: hdr_byte = (m == 2'd1) ? "S" : (m == 2'd2) ? "B" : "C";
            3'd4: hdr_byte = BYTES[7:0];
            3'd5: hdr_byte = BYTES[15:8];
            3'd6: hdr_byte = BYTES[23:16];
            default: hdr_byte = BYTES[31:24];
        endcase
    endfunction

    reg [12:0] gap_cnt;
    wire can_send = tx_ready && !tx_valid && gap_cnt == 0;
    always @(posedge clk) begin
        if (rst || tx_valid)   gap_cnt <= GAP[12:0];
        else if (gap_cnt != 0) gap_cnt <= gap_cnt - 13'd1;
    end

    // Symbol packing: 8 symbols per word, first symbol in byte 0.
    reg [55:0] pack;
    reg [2:0]  pack_n;

    always @(posedge clk) begin
        tx_valid <= 1'b0;
        wen      <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else case (state)
            S_IDLE: if (rx_valid && (rx_data == "C" || rx_data == "S" || rx_data == "B")) begin
                mode     <= (rx_data == "S") ? 2'd1 : (rx_data == "B") ? 2'd2 : 2'd0;
                waddr    <= {DEPTH_LOG2{1'b1}};   // first write wraps to 0
                pack_n   <= 0;
                state    <= S_CAP;
            end
            S_CAP: begin
                if (mode == 2'd0) begin
                    wdata <= win;
                    wen   <= 1'b1;
                    waddr <= waddr + 1'b1;
                end else if (mode == 2'd2) begin
                    if (fm_valid) begin
                        pack[31:0] <= {{2{fm_vid[13]}}, fm_vid, 8'd0, fm_sym};
                        pack_n     <= pack_n + 3'd1;
                        if (pack_n[0]) begin
                            wdata <= {{2{fm_vid[13]}}, fm_vid, 8'd0, fm_sym, pack[31:0]};
                            wen   <= 1'b1;
                            waddr <= waddr + 1'b1;
                        end
                    end
                end else if (sym_valid) begin
                    pack   <= {sym, pack[55:8]};
                    pack_n <= pack_n + 3'd1;
                    if (pack_n == 3'd7) begin
                        wdata <= {sym, pack};
                        wen   <= 1'b1;
                        waddr <= waddr + 1'b1;
                    end
                end
                // waddr holds the address of the word being written this
                // clock; stop after the last one.
                if (wen && waddr == DEPTH - 1) begin
                    wen   <= 1'b0;
                    idx   <= 0;
                    state <= S_HDR;
                end
            end
            S_HDR: if (can_send) begin
                tx_data  <= hdr_byte(idx, mode);
                tx_valid <= 1'b1;
                idx      <= idx + 3'd1;
                if (idx == 3'd7) begin
                    raddr    <= 0;
                    wait_cnt <= 0;
                    state    <= S_RD;
                end
            end
            S_RD: begin   // allow for BSRAM read latency
                wait_cnt <= wait_cnt + 2'd1;
                if (wait_cnt == 2'd3) begin
                    idx   <= 0;
                    state <= S_SEND;
                end
            end
            S_SEND: if (can_send) begin
                tx_data  <= rdata[idx * 8 +: 8];
                tx_valid <= 1'b1;
                idx      <= idx + 3'd1;
                if (idx == 3'd7) begin
                    raddr    <= raddr + 1'b1;
                    wait_cnt <= 0;
                    state    <= (&raddr) ? S_IDLE : S_RD;
                end
            end
            default: state <= S_IDLE;
        endcase
    end

    // Per-pin transition counters, one pipeline stage after the samples.
    reg [7:0]  last;
    reg [7:0]  tr [0:7];     // tr[j] = pins that changed into sample j
    reg [19:0] window;
    reg        latch;

    integer j;
    always @(posedge clk) begin
        last  <= win[63:56];
        tr[0] <= last ^ win[7:0];
        for (j = 1; j < 8; j = j + 1) tr[j] <= win[j*8 +: 8] ^ win[(j-1)*8 +: 8];
        window <= window + 20'd1;
        latch  <= &window;
    end

    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_cnt
            reg [21:0] cnt;
            wire [3:0] add = tr[0][k] + tr[1][k] + tr[2][k] + tr[3][k]
                           + tr[4][k] + tr[5][k] + tr[6][k] + tr[7][k];
            always @(posedge clk) begin
                if (latch) begin
                    activity[k*22 +: 22] <= cnt;
                    cnt <= {18'd0, add};
                end else begin
                    cnt <= cnt + add;
                end
            end
        end
    endgenerate
endmodule
