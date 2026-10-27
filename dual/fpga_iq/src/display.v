// 1280x720p output (75 MHz pixel clock, 1650 x 750 total, ~60.6 Hz).
//
// Modes (mode_dual):
//   0  diversity: the receiver with the better field (quality, lower is
//      better) is shown 960x720, centred.  The choice is made once per output
//      frame with hysteresis.
//   1  dual: receiver A left, receiver B right, each 640x480 (4:3), centred
//      vertically.
//
// Fields are shown "bob" style: every field is scaled to the full picture
// height on its own (no weaving, lowest latency).  The lower field of each
// pair is offset by half a field line so the two fields line up.
//
// Source lines are fetched from SDRAM into a 4-slot line buffer per receiver,
// running up to two source lines ahead of the line being displayed.
module display #(
    parameter BOB_SWAP = 1'b0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        mode_dual,

    // receiver status (from chan_buf)
    input  wire [1:0]  done_valid,
    input  wire [3:0]  done_buf,      // {B, A}
    input  wire [1:0]  done_par,
    input  wire [1:0]  done_pal,
    input  wire [31:0] done_q,
    output reg  [3:0]  lock_buf,
    output reg  [1:0]  lock_valid,
    output reg         sel_ch,        // diversity: receiver on screen

    // SDRAM read port
    output reg         r_req,
    output reg  [21:0] r_base,
    input  wire        r_take,
    input  wire        r_ack,
    input  wire        r_we,
    input  wire [9:0]  r_idx,
    input  wire [15:0] r_data,

    // video
    output reg  [7:0]  vid_r,
    output reg  [7:0]  vid_g,
    output reg  [7:0]  vid_b,
    output reg         vid_de,
    output reg         vid_hs,
    output reg         vid_vs
);

    localparam [10:0] H_ACT = 11'd1280, H_TOT = 11'd1650, HS_0 = 11'd1390, HS_1 = 11'd1430;
    localparam [9:0]  V_ACT = 10'd720,  V_TOT = 10'd750,  VS_0 = 10'd725,  VS_1 = 10'd730;

    // ---------------- timing ----------------
    reg [10:0] hc;
    reg [9:0]  vc;
    always @(posedge clk) begin
        if (rst) begin
            hc <= 11'd0; vc <= 10'd0;
        end else if (hc == H_TOT - 11'd1) begin
            hc <= 11'd0;
            vc <= (vc == V_TOT - 10'd1) ? 10'd0 : vc + 10'd1;
        end else
            hc <= hc + 11'd1;
    end

    wire frame_start = (hc == 11'd0) && (vc == V_ACT);       // start of vertical blanking
    wire line_end    = (hc == H_ACT);                        // end of the visible part of a line

    // ---------------- per-frame lock ----------------
    reg        dual;                 // mode latched per frame
    reg [1:0]  l_pal, l_par;
    reg [9:0]  l_n0, l_n1;           // source lines per field
    reg [16:0] stepv0, stepv1;       // source lines per output row, 1.16

    function [16:0] vstep(input pal, input d);
        // N / image height in 1.16 fixed point
        case ({d, pal})
            2'b00: vstep = 17'd21845;   // 240 / 720
            2'b01: vstep = 17'd26214;   // 288 / 720
            2'b10: vstep = 17'd32768;   // 240 / 480
            default: vstep = 17'd39322; // 288 / 480
        endcase
    endfunction

    // the lower field starts half a source line earlier
    function lower(input pal, input par);
        lower = (pal ? par : !par) ^ BOB_SWAP;
    endfunction

    // diversity selection with hysteresis
    wire [15:0] qa = done_q[15:0], qb = done_q[31:16];
    wire [15:0] q_sel = sel_ch ? qb : qa;
    wire [15:0] q_oth = sel_ch ? qa : qb;
    wire        v_sel = done_valid[sel_ch];
    wire        v_oth = done_valid[!sel_ch];
    wire [16:0] q_need = {1'b0, q_oth} + {4'd0, q_sel[15:3]} + 17'd8;

    // ---------------- vertical position per receiver ----------------
    reg signed [26:0] vacc0, vacc1;          // source line, 11.16
    wire [9:0] src0 = vacc0[26] ? 10'd0 : vacc0[25:16];
    wire [9:0] src1 = vacc1[26] ? 10'd0 : vacc1[25:16];
    reg        img_rows;                     // current output line is inside the picture
    wire       row_in_img = dual ? (vc >= 10'd120 && vc < 10'd600) : (vc < V_ACT);

    // ---------------- fetch engine ----------------
    reg  [9:0] fnext0, fnext1;    // next source line to fetch
    reg        fbusy, fch, fpend_reset;
    reg  [1:0] fslot;
    wire       use0 = dual || !sel_ch;
    wire       use1 = dual || sel_ch;
    wire       want0 = use0 && lock_valid[0] && fnext0 < l_n0 && fnext0 <= src0 + 10'd2;
    wire       want1 = use1 && lock_valid[1] && fnext1 < l_n1 && fnext1 <= src1 + 10'd2;

    always @(posedge clk) begin
        if (rst) begin
            dual <= 1'b0; sel_ch <= 1'b0; lock_buf <= 4'd0; lock_valid <= 2'b00;
            l_pal <= 2'b00; l_par <= 2'b00; l_n0 <= 10'd240; l_n1 <= 10'd240;
            stepv0 <= 17'd21845; stepv1 <= 17'd21845;
            vacc0 <= 27'sd0; vacc1 <= 27'sd0;
            fnext0 <= 10'd0; fnext1 <= 10'd0; fbusy <= 1'b0; fpend_reset <= 1'b0;
            r_req <= 1'b0;
        end else begin
            if (frame_start) begin
                dual       <= mode_dual;
                lock_buf   <= done_buf;
                lock_valid <= done_valid;
                l_pal      <= done_pal;
                l_par      <= done_par;
                l_n0       <= done_pal[0] ? 10'd288 : 10'd240;
                l_n1       <= done_pal[1] ? 10'd288 : 10'd240;
                stepv0     <= vstep(done_pal[0], mode_dual);
                stepv1     <= vstep(done_pal[1], mode_dual);
                vacc0      <= lower(done_pal[0], done_par[0]) ? -27'sd32768 : 27'sd0;
                vacc1      <= lower(done_pal[1], done_par[1]) ? -27'sd32768 : 27'sd0;
                if (!v_sel && v_oth) sel_ch <= !sel_ch;
                else if (v_sel && v_oth && q_need[16:0] < {1'b0, q_sel}) sel_ch <= !sel_ch;
                fpend_reset <= 1'b1;
            end else if (line_end && row_in_img) begin
                vacc0 <= vacc0 + $signed({10'd0, stepv0});
                vacc1 <= vacc1 + $signed({10'd0, stepv1});
            end

            // fetch scheduling (one line request at a time)
            if (r_ack) fbusy <= 1'b0;
            if (fpend_reset && !fbusy && !r_req) begin
                fpend_reset <= 1'b0;
                fnext0 <= src0;
                fnext1 <= src1;
            end else if (!fbusy && !r_req && !fpend_reset && !frame_start) begin
                if (want0 && (!want1 || fnext0 - src0 <= fnext1 - src1)) begin
                    r_req  <= 1'b1;
                    r_base <= {1'b0, lock_buf[1:0], fnext0[8:0], 10'd0};
                    fch    <= 1'b0;
                    fslot  <= fnext0[1:0];
                    fnext0 <= fnext0 + 10'd1;
                    fbusy  <= 1'b1;
                end else if (want1) begin
                    r_req  <= 1'b1;
                    r_base <= {1'b1, lock_buf[3:2], fnext1[8:0], 10'd0};
                    fch    <= 1'b1;
                    fslot  <= fnext1[1:0];
                    fnext1 <= fnext1 + 10'd1;
                    fbusy  <= 1'b1;
                end
            end
            if (r_take) r_req <= 1'b0;
        end
    end

    // ---------------- line buffers: 4 slots x 1024 per receiver ----------------
    reg [15:0] lb0 [0:4095];
    reg [15:0] lb1 [0:4095];
    always @(posedge clk) begin
        if (r_we && !fch) lb0[{fslot, r_idx}] <= r_data;
        if (r_we &&  fch) lb1[{fslot, r_idx}] <= r_data;
    end

    // ---------------- pixel pipeline ----------------
    // stage 0: which picture, source x, read addresses
    reg [16:0] xacc;          // diversity horizontal DDA, 10.16 -> 640 over 960
    reg        p0_img, p0_ch, p0_act, p0_box;
    reg [11:0] a0, a1;
    reg [10:0] ix;            // x inside the picture
    reg [9:0]  iy;            // y inside the picture
    wire       h_act = hc < H_ACT;
    wire       v_act = vc < V_ACT;
    wire       in_div = !dual && hc >= 11'd160 && hc < 11'd1120;
    wire       ch_now = dual ? (hc >= 11'd640) : sel_ch;
    wire [9:0] sx = dual ? (hc >= 11'd640 ? hc[9:0] - 10'd640 : hc[9:0]) : xacc[16:7];
    reg  [7:0] rd0, rd1;

    always @(posedge clk) begin
        // horizontal DDA for the 1.5x diversity picture
        if (hc == 11'd159) xacc <= 17'd0;
        else if (in_div) xacc <= xacc + 17'd85;     // 2/3 in 0.7 fixed point (128 = 1 pixel)

        iy <= dual ? vc - 10'd120 : vc;
        p0_act <= h_act && v_act;
        p0_img <= h_act && v_act && row_in_img && (dual || in_div);
        p0_ch  <= ch_now;
        ix     <= dual ? (hc >= 11'd640 ? hc - 11'd640 : hc) : hc - 11'd160;
        a0     <= {src0[1:0], sx};
        a1     <= {src1[1:0], sx};
    end

    // stage 1: line-buffer read
    reg        p1_img, p1_ch, p1_act, p1_box, p1_val;
    always @(posedge clk) begin
        rd0    <= lb0[a0][15:8];
        rd1    <= lb1[a1][15:8];
        p1_img <= p0_img;
        p1_ch  <= p0_ch;
        p1_act <= p0_act;
        p1_val <= lock_valid[p0_ch];
        // status square in the top-left corner of each picture
        p1_box <= p0_img && ix >= 11'd8 && ix < 11'd24 && iy >= 10'd8 && iy < 10'd24;
    end

    // stage 2: colour
    wire [7:0] y = p1_ch ? rd1 : rd0;
    reg [23:0] rgb;
    always @(*) begin
        if (!p1_img)
            rgb = 24'h000000;
        else if (p1_box)
            rgb = !p1_val ? 24'hff2020 : (dual ? 24'h20ff20 : (p1_ch ? 24'hff20ff : 24'h20ff20));
        else if (!p1_val)
            rgb = 24'h101040;
        else
            rgb = {y, y, y};
    end

    // syncs delayed to match the 3-stage pixel pipeline
    reg [2:0] hs_d, vs_d, de_d;
    always @(posedge clk) begin
        hs_d <= {hs_d[1:0], hc >= HS_0 && hc < HS_1};
        vs_d <= {vs_d[1:0], vc >= VS_0 && vc < VS_1};
        de_d <= {de_d[1:0], h_act && v_act && !rst};
        vid_hs <= hs_d[1];
        vid_vs <= vs_d[1];
        vid_de <= de_d[1];
        {vid_r, vid_g, vid_b} <= p1_act ? rgb : 24'h000000;
    end

endmodule
