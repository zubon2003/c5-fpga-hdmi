// DVI 1.0 TMDS 8b/10b encoder (transition minimised, DC balanced).
// Output bit 0 is transmitted first.
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire       de,
    input  wire [1:0] ctrl,
    input  wire [7:0] din,
    output reg  [9:0] dout
);
    function [3:0] ones8(input [7:0] v);
        ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction

    wire [3:0] n1d = ones8(din);
    wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !din[0]);

    wire [8:0] q_m;
    assign q_m[0] = din[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : g_qm
            assign q_m[i] = use_xnor ? ~(q_m[i-1] ^ din[i]) : (q_m[i-1] ^ din[i]);
        end
    endgenerate
    assign q_m[8] = ~use_xnor;

    wire [3:0] n1q = ones8(q_m[7:0]);
    wire signed [4:0] diff = $signed({1'b0, n1q}) - $signed(5'd4);  // (ones - zeros) / 2
    reg  signed [4:0] cnt;   // running disparity / 2

    always @(posedge clk) begin
        if (rst) begin
            dout <= 10'd0;
            cnt  <= 5'sd0;
        end else if (!de) begin
            cnt <= 5'sd0;
            case (ctrl)
                2'b00: dout <= 10'b1101010100;
                2'b01: dout <= 10'b0010101011;
                2'b10: dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            dout <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            cnt  <= q_m[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            dout <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt  <= cnt + $signed({4'b0, q_m[8]}) - diff;
        end else begin
            dout <= {1'b0, q_m[8], q_m[7:0]};
            cnt  <= cnt - $signed({4'b0, ~q_m[8]}) + diff;
        end
    end
endmodule
