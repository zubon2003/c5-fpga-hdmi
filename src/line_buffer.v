// 16 lines x 1024 words of {Y, C}, written in the IQ domain, read in the
// pixel domain with one clock of latency.
module line_buffer (
    input  wire        wclk,
    input  wire        we,
    input  wire [13:0] waddr,
    input  wire [15:0] wdata,
    input  wire        rclk,
    input  wire [13:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] mem [0:16383];
    always @(posedge wclk) if (we) mem[waddr] <= wdata;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
