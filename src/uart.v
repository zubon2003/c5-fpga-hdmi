// 8N1 UART, fixed divider. DIV = clock / baud.
module uart_tx #(parameter DIV = 135) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output reg        txd
);
    reg [9:0]  shift;
    reg [3:0]  bits;
    reg [15:0] cnt;

    assign ready = (bits == 0);

    // Start bit goes out on accept; ten ticks later the stop bit has had
    // a full bit time.
    always @(posedge clk) begin
        if (rst) begin
            txd  <= 1'b1;
            bits <= 0;
            cnt  <= 0;
        end else if (bits == 0) begin
            if (valid) begin
                txd   <= 1'b0;
                shift <= {2'b11, data};
                bits  <= 4'd10;
                cnt   <= 0;
            end
        end else if (cnt == DIV - 1) begin
            cnt  <= 0;
            bits <= bits - 4'd1;
            if (bits != 4'd1) begin
                txd   <= shift[0];
                shift <= {1'b1, shift[9:1]};
            end
        end else begin
            cnt <= cnt + 16'd1;
        end
    end
endmodule

module uart_rx #(parameter DIV = 135) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg        valid,
    output reg  [7:0] data
);
    reg [2:0]  sync = 3'b111;
    reg [3:0]  bits;
    reg [15:0] cnt;
    reg [7:0]  shift;

    always @(posedge clk) begin
        sync  <= {sync[1:0], rxd};
        valid <= 1'b0;
        if (rst) begin
            bits <= 0;
        end else if (bits == 0) begin
            if (!sync[2]) begin           // start bit edge
                bits <= 4'd10;
                cnt  <= DIV / 2;
            end
        end else if (cnt == DIV - 1) begin
            cnt <= 0;
            bits <= bits - 4'd1;
            if (bits == 4'd10) begin
                if (sync[2]) bits <= 0;   // false start
            end else if (bits == 4'd1) begin
                if (sync[2]) begin        // stop bit
                    data  <= shift;
                    valid <= 1'b1;
                end
            end else begin
                shift <= {sync[2], shift[7:1]};
            end
        end else begin
            cnt <= cnt + 16'd1;
        end
    end
endmodule
