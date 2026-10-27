// Debounced push button: one pulse per press (input active high).
module button #(
    parameter integer TICK = 75_000        // 1 ms at 75 MHz
) (
    input  wire clk,
    input  wire rst,
    input  wire btn,
    output reg  press
);
    reg [1:0]  sync;
    reg [16:0] div;
    reg [3:0]  hist;
    reg        state;
    always @(posedge clk) begin
        sync  <= {sync[0], btn};
        press <= 1'b0;
        if (rst) begin
            div <= 17'd0; hist <= 4'd0; state <= 1'b0;
        end else if (div == TICK[16:0]) begin
            div  <= 17'd0;
            hist <= {hist[2:0], sync[1]};
            if (hist == 4'b1111 && !state) begin state <= 1'b1; press <= 1'b1; end
            if (hist == 4'b0000) state <= 1'b0;
        end else
            div <= div + 17'd1;
    end
endmodule
