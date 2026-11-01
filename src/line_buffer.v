// 8 lines x 640 words of {Y, C} (address = line * 640 + pixel), one write
// and one read clock; read with one clock of latency. Used twice: the input
// ring (video_in -> sdram_fb) and the output ring (sdram_fb -> display).
module line_buffer (
    input  wire        wclk,
    input  wire        we,
    input  wire [14:0] waddr,
    input  wire [15:0] wdata,
    input  wire        rclk,
    input  wire [14:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] mem [0:5119];
    always @(posedge wclk) if (we) mem[waddr] <= wdata;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
