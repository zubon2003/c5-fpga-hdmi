// 16 lines x 2048 bytes, written in the IQ domain, read in the pixel
// domain with one clock of latency.
module line_buffer (
    input  wire        wclk,
    input  wire        we,
    input  wire [14:0] waddr,
    input  wire [7:0]  wdata,
    input  wire        rclk,
    input  wire [14:0] raddr,
    output reg  [7:0]  rdata
);
    reg [7:0] mem [0:32767];
    always @(posedge wclk) if (we) mem[waddr] <= wdata;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
