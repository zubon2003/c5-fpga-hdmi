// DVI 1.0 TMDS encoder (8b/10b with DC balancing), one channel.
module tmds_enc (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] d,
    input  wire [1:0] c,
    input  wire       de,
    output reg  [9:0] q
);
    function [3:0] ones8(input [7:0] v);
        integer i;
        begin
            ones8 = 4'd0;
            for (i = 0; i < 8; i = i + 1) ones8 = ones8 + {3'd0, v[i]};
        end
    endfunction

    wire [3:0] n1d = ones8(d);
    wire       use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : g_qm
            assign qm[i] = use_xnor ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
        end
    endgenerate
    assign qm[8] = ~use_xnor;

    wire [3:0] n1q = ones8(qm[7:0]);
    wire signed [5:0] diff = $signed({2'b00, n1q}) - $signed(6'd4);   // (n1 - n0) / 2
    reg  signed [5:0] cnt;                                             // running disparity / 2

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 6'sd0;
            q   <= 10'b1101010100;
        end else if (!de) begin
            cnt <= 6'sd0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 6'sd0 || diff == 6'sd0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 6'sd0 && diff > 6'sd0) || (cnt < 6'sd0 && diff < 6'sd0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + (qm[8] ? 6'sd1 : 6'sd0) - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - (qm[8] ? 6'sd0 : 6'sd1) + diff;
        end
    end
endmodule
