// 1280x720p60 (CEA-861 VIC 4) timing: 1650 x 750 total, positive syncs.
// At the 74.48 MHz pixel clock this runs at 60.19 Hz.
//
// Genlock: the last line of the frame (back porch) repeats until `go` has
// been seen, at most MAX_HOLD extra lines, so the output frame follows the
// input field (59.94 Hz: about 753 lines per frame). Without input the
// frame is 750 + MAX_HOLD lines.
module video_timing #(
    parameter MAX_HOLD = 8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,            // pulse: start the next frame
    output reg  [10:0] x,
    output reg  [9:0]  y,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg         frame_start,
    output reg         line_start
);
    localparam H_ACTIVE = 1280, H_FP = 110, H_SYNC = 40, H_BP = 220;
    localparam V_ACTIVE = 720,  V_FP = 5,   V_SYNC = 5,  V_BP = 20;
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1650
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 750

    reg [10:0] hc;
    reg [9:0]  vc;
    reg        pending;
    reg [3:0]  hold;

    always @(posedge clk) begin
        if (rst) begin
            hc <= 0;
            vc <= 0;
            pending <= 1'b0;
            hold <= 0;
        end else begin
            if (go) pending <= 1'b1;
            if (hc == H_TOTAL - 1) begin
                hc <= 0;
                if (vc != V_TOTAL - 1) begin
                    vc <= vc + 10'd1;
                end else if (pending || go || hold == MAX_HOLD) begin
                    vc      <= 0;
                    hold    <= 0;
                    pending <= 1'b0;
                end else begin
                    hold <= hold + 4'd1;            // repeat the last line
                end
            end else begin
                hc <= hc + 11'd1;
            end
        end
    end

    // Registered outputs: one pixel of latency, same for every signal.
    always @(posedge clk) begin
        x           <= hc;
        y           <= vc;
        de          <= (hc < H_ACTIVE) && (vc < V_ACTIVE);
        hsync       <= (hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC);
        vsync       <= (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);
        frame_start <= (hc == 0) && (vc == 0);
        line_start  <= (hc == 0);
    end
endmodule
