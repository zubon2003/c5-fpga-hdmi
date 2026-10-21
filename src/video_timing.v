// 720x480p59.94 (CEA-861 VIC 2/3) timing at a 27 MHz pixel clock.
// 858 x 525 total, negative hsync/vsync.
module video_timing (
    input  wire        clk,
    input  wire        rst,
    output reg  [9:0]  x,
    output reg  [9:0]  y,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg         frame_start
);
    localparam H_ACTIVE = 720, H_FP = 16, H_SYNC = 62, H_BP = 60;
    localparam V_ACTIVE = 480, V_FP = 9,  V_SYNC = 6,  V_BP = 30;
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 858
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

    reg [9:0] hc, vc;

    always @(posedge clk) begin
        if (rst) begin
            hc <= 0;
            vc <= 0;
        end else if (hc == H_TOTAL - 1) begin
            hc <= 0;
            vc <= (vc == V_TOTAL - 1) ? 10'd0 : vc + 10'd1;
        end else begin
            hc <= hc + 10'd1;
        end
    end

    // Registered outputs: one pixel of latency, same for every signal.
    always @(posedge clk) begin
        x           <= hc;
        y           <= vc;
        de          <= (hc < H_ACTIVE) && (vc < V_ACTIVE);
        hsync       <= ~((hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC));
        vsync       <= ~((vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC));
        frame_start <= (hc == 0) && (vc == 0);
    end
endmodule
