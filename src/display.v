// 1280x720 status display, three pipeline stages (74.48 MHz pixel clock):
//   y 0..479    waveform monitor of one demodulated line (scope_line):
//               1280 samples at 20 MS/s = 64 us across, 200 px = 10 us grid,
//               y = 240 - vid * 3 / 16, so 38.4 px per MHz
//   y 500..695  10 bars, 16 px high, 20 px apart:
//               rows 0..7 IQ pin n transitions per 12.4 ms / 512,
//               rows 8, 9 resampler early / late votes per 0.78 ms / 64
// The scope RAM is read with address x at stage 0, its data arrives with
// stage 1. Counts come from the IQ domain and are only displayed.
//
// Picture mode (pic_mode = 1) shows the demodulated luma instead: output
// line y shows field line y / 3 (one more output line for the second field,
// half an input line lower), read from the line buffer at {line [3:0], x}.
module display (
    input  wire               clk,
    input  wire [10:0]        x,
    input  wire [9:0]         y,
    input  wire               de,
    input  wire               hsync,
    input  wire               vsync,
    input  wire               line_start,
    input  wire [175:0]       activity,
    input  wire [15:0]        early_cnt,
    input  wire [15:0]        late_cnt,
    input  wire signed [13:0] sc_rd,
    input  wire               sc_trig,
    input  wire               pic_mode,
    input  wire               parity,
    output reg  [14:0]        pic_addr,
    input  wire [7:0]         pic,
    output reg  [23:0]        rgb,
    output reg                de_o,
    output reg                hsync_o,
    output reg                vsync_o
);
    // ---- per-line state: bar row and length ----
    reg [3:0]  r;
    reg [4:0]  p;
    reg [12:0] cnt;
    reg [10:0] len;
    wire in_bars = (y >= 500) && (r < 10) && (p < 16);

    always @(posedge clk) begin
        if (line_start) begin
            if (y == 500)    begin r <= 0;        p <= 0;        end
            else if (p == 19) begin r <= r + 4'd1; p <= 0;        end
            else                    p <= p + 5'd1;
        end
        if (x == 1) begin
            case (r)
                4'd0: cnt <= activity[  9 +: 13];
                4'd1: cnt <= activity[ 31 +: 13];
                4'd2: cnt <= activity[ 53 +: 13];
                4'd3: cnt <= activity[ 75 +: 13];
                4'd4: cnt <= activity[ 97 +: 13];
                4'd5: cnt <= activity[119 +: 13];
                4'd6: cnt <= activity[141 +: 13];
                4'd7: cnt <= activity[163 +: 13];
                4'd8: cnt <= {3'd0, early_cnt[15:6]};
                default: cnt <= {3'd0, late_cnt[15:6]};
            endcase
        end
        if (x == 2) len <= (cnt > 13'd1260) ? 11'd1260 : cnt[10:0];
    end

    // ---- picture: field line for this output line ----
    reg [7:0] src;
    reg [1:0] c3;
    always @(posedge clk) begin
        if (line_start) begin
            if (y == 0)       begin src <= 0;          c3 <= parity ? 2'd3 : 2'd0; end
            else if (c3 == 2) begin src <= src + 8'd1; c3 <= 2'd0;                 end
            else                     c3 <= c3 + 2'd1;
        end
    end
    always @(*) pic_addr = {src[3:0], x};

    // ---- stage 1 ----
    reg [9:0]  y1;
    reg        de1, hs1, vs1, sc1, grid1, led1, bar1, mark1;
    reg [3:0]  r1;
    always @(posedge clk) begin
        y1    <= y;
        de1   <= de;
        hs1   <= hsync;
        vs1   <= vsync;
        r1    <= r;
        sc1   <= (y < 480);
        grid1 <= (y == 240) || (x == 200) || (x == 400) || (x == 600) ||
                 (x == 800) || (x == 1000) || (x == 1200);
        led1  <= (x >= 1248) && (x < 1268) && (y >= 8) && (y < 28);
        bar1  <= in_bars && (x >= 12) && (x < 12 + len);
        mark1 <= in_bars && (x < 10);
    end

    // ---- stage 2: trace position ----
    wire signed [15:0] v3  = sc_rd + (sc_rd <<< 1);
    wire signed [15:0] t_s = 16'sd240 - (v3 >>> 4);
    reg  [9:0] ty2, typ;
    reg  [9:0] y2;
    reg        de2, hs2, vs2, sc2, grid2, led2, bar2, mark2;
    reg  [3:0] r2;
    reg  [7:0] pic2;
    reg        pm2;
    always @(posedge clk) begin
        pic2  <= pic;
        pm2   <= pic_mode;
        ty2   <= (t_s < 0) ? 10'd0 : (t_s > 16'sd479) ? 10'd479 : t_s[9:0];
        typ   <= ty2;
        y2    <= y1;
        de2   <= de1;
        hs2   <= hs1;
        vs2   <= vs1;
        sc2   <= sc1;
        grid2 <= grid1;
        led2  <= led1;
        bar2  <= bar1;
        mark2 <= mark1;
        r2    <= r1;
    end

    // ---- stage 3: colour ----
    wire [9:0] t_lo = (ty2 < typ) ? ty2 : typ;
    wire [9:0] t_hi = (ty2 < typ) ? typ : ty2;
    wire trace = (y2 >= t_lo) && (y2 <= t_hi);
    always @(posedge clk) begin
        de_o    <= de2;
        hsync_o <= hs2;
        vsync_o <= vs2;
        if (led2)                 rgb <= sc_trig ? 24'h20d040 : 24'hd03020;
        else if (pm2)             rgb <= {pic2, pic2, pic2};
        else if (sc2 && trace)    rgb <= 24'hf0f070;
        else if (sc2 && grid2)    rgb <= 24'h303840;
        else if (sc2)             rgb <= 24'h0c1014;
        else if (bar2)
            case (r2)
                4'd3:    rgb <= 24'hff8000;   // Q sign
                4'd7:    rgb <= 24'h4080ff;   // I sign
                4'd8:    rgb <= 24'he04060;   // early votes
                4'd9:    rgb <= 24'h60c040;   // late votes
                default: rgb <= r2[2] ? 24'h00e0e0 : 24'he0e000;
            endcase
        else if (mark2)           rgb <= r2[3] ? 24'h404040 : r2[2] ? 24'h006060 : 24'h606000;
        else                      rgb <= 24'h000000;
    end
endmodule
