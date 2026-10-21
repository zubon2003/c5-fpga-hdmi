// Test pattern: 75 % colour bars on the top two thirds, a grey ramp below,
// a one-pixel white border and a square that moves every frame (proves the
// output is live, not a frozen sink buffer).
module test_pattern (
    input  wire       clk,
    input  wire       rst,
    input  wire [9:0] x,
    input  wire [9:0] y,
    input  wire       frame_start,
    output reg  [7:0] r,
    output reg  [7:0] g,
    output reg  [7:0] b
);
    reg [9:0] bx;
    reg [8:0] by;
    reg       dx, dy;

    always @(posedge clk) begin
        if (rst) begin
            bx <= 10'd40; by <= 9'd40; dx <= 1'b0; dy <= 1'b0;
        end else if (frame_start) begin
            bx <= dx ? bx - 10'd2 : bx + 10'd2;
            by <= dy ? by - 9'd2 : by + 9'd2;
            if (!dx && bx >= 10'd720 - 32 - 4) dx <= 1'b1;
            if ( dx && bx <= 10'd4)            dx <= 1'b0;
            if (!dy && by >= 9'd480 - 32 - 4)  dy <= 1'b1;
            if ( dy && by <= 9'd4)             dy <= 1'b0;
        end
    end

    // 720 / 8 = 90 pixels per bar.
    wire [2:0] bar = (x < 90)  ? 3'd0 : (x < 180) ? 3'd1 : (x < 270) ? 3'd2 :
                     (x < 360) ? 3'd3 : (x < 450) ? 3'd4 : (x < 540) ? 3'd5 :
                     (x < 630) ? 3'd6 : 3'd7;
    wire [16:0] ramp = x * 7'd91;   // x * 256 / 720, 0..255
    wire border = (x == 0) || (x == 719) || (y == 0) || (y == 479);
    wire box    = (x >= bx) && (x < bx + 32) && (y >= by) && (y < by + 32);

    always @(posedge clk) begin
        if (border || box) begin
            {r, g, b} <= 24'hffffff;
        end else if (y < 320) begin
            // white, yellow, cyan, green, magenta, red, blue, black
            case (bar)
                3'd0: {r, g, b} <= {8'd191, 8'd191, 8'd191};
                3'd1: {r, g, b} <= {8'd191, 8'd191, 8'd0};
                3'd2: {r, g, b} <= {8'd0,   8'd191, 8'd191};
                3'd3: {r, g, b} <= {8'd0,   8'd191, 8'd0};
                3'd4: {r, g, b} <= {8'd191, 8'd0,   8'd191};
                3'd5: {r, g, b} <= {8'd191, 8'd0,   8'd0};
                3'd6: {r, g, b} <= {8'd0,   8'd0,   8'd191};
                default: {r, g, b} <= 24'h000000;
            endcase
        end else begin
            {r, g, b} <= {3{ramp[15:8]}};
        end
    end
endmodule
