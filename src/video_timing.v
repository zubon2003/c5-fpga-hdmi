// 1280x720p timing, 750 lines per frame always, positive syncs.
//
// Genlock by line length: the frame must follow the input field (59.94 Hz)
// because the line ring holds only 16 lines. Repeating the last line until
// the input was ready (the first version) made frames 752..754 lines long;
// the capture card took that, but an HDMI monitor did not show the picture.
// Now the line count stays 750 and the line length moves instead:
//   BASE = 1657 pixels at 74.48 MHz: 59.93 Hz, close to the input;
//   E pixels per frame (|E| <= 750) go into the five vertical front porch
//   lines (720..724, just before vsync), E / 5 each; all other lines are
//   exactly BASE. Spreading E one pixel per line over the whole frame made
//   the capture card shear the picture: it seems to place pixels by their
//   count from vsync at a fixed line length, so every longer line moved all
//   lines below it.
//   The line counter starts at the hsync, so a changed line length only
//   moves that line's front porch.
// Each `go` (input field ready) measures the phase p = how far the output
// frame is ahead of the wanted position (go at line TARGET, pixel 0), in
// pixels; e = p / 16; E = e + I, I += e / 16 (host simulation of this loop:
// peak error ~2.5 lines while locking, then within ~0.1 line). A go more
// than JUMP lines off, or the first go after 3 frames without one, moves
// the counters straight to TARGET once (one disturbed frame).
// Without go the frame free-runs at BASE (59.93 Hz).
module video_timing (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,            // pulse: input field ready
    output reg  [10:0] x,
    output reg  [9:0]  y,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg         frame_start,
    output reg         line_start,
    output reg  [15:0] jumps          // re-acquisitions so far (status)
);
    localparam H_ACTIVE = 1280, H_SYNC = 40, H_BP = 227;     // front porch: the rest (~110)
    localparam [10:0] H_START = H_SYNC + H_BP;                // first picture pixel: 267
    localparam V_ACTIVE = 720,  V_FP = 5,   V_SYNC = 5,  V_BP = 20;
    localparam [10:0] BASE    = 11'd1657;
    localparam [9:0]  V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 750
    localparam [9:0]  TARGET  = 10'd745;     // go 5 lines before the frame starts
    localparam [9:0]  JUMP    = 10'd8;

    reg [10:0] hc;
    reg [9:0]  vc;
    reg [10:0] h_last;                       // last pixel of this line
    reg signed [10:0] e_frame;               // E for the current frame
    reg signed [10:0] e_line;                // E / 5 for the porch lines
    reg signed [10:0] e_last;                // E - 4 (E / 5) for line 724
    reg signed [10:0] integ;
    reg [1:0]  since_go;                     // frames without a go, saturating at 3
    reg        locked;
    reg        stray;                        // the last go was far from TARGET

    // Phase of a go, computed over three clocks after it (once per frame):
    // lines from TARGET wrapped to -375..374, then pixels, then the loop.
    reg [9:0]  vc_go;
    reg [10:0] hc_go;
    reg [2:0]  ph;                           // pipeline stage valid bits
    reg signed [10:0] dv;
    reg signed [22:0] p_px;
    wire signed [10:0] dv_raw = $signed({1'b0, vc_go}) - $signed({1'b0, TARGET});
    wire signed [18:0] e_w    = p_px >>> 4;
    wire signed [19:0] e_sum  = e_w + integ;
    wire signed [10:0] e_next = (e_sum > 20'sd750) ? 11'sd750 : (e_sum < -20'sd750) ? -11'sd750 : e_sum[10:0];
    wire signed [19:0] i_sum  = integ + (e_w >>> 4);
    wire signed [10:0] i_next = (i_sum > 20'sd750) ? 11'sd750 : (i_sum < -20'sd750) ? -11'sd750 : i_sum[10:0];
    // Cheap test at the go itself: close enough to TARGET to stay locked?
    wire near = (vc >= TARGET - JUMP) && (vc <= TARGET + JUMP);

    // E / 5 as E * 205 / 1024 (exact enough for |E| <= 750).
    wire signed [21:0] e5_w = e_frame * 11'sd205;
    wire signed [10:0] e5   = e5_w >>> 10;
    always @(posedge clk) begin
        e_line <= e5;
        e_last <= e_frame - (e5 <<< 2);
    end
    // Length of the next line: vc is the line that ends now, so the next
    // one is vc + 1.
    wire [9:0] vn = (vc == V_TOTAL - 1) ? 10'd0 : vc + 10'd1;
    wire signed [11:0] h_next = $signed({1'b0, BASE}) - 12'sd1 +
                                ((vn >= 10'd720 && vn <= 10'd723) ? e_line :
                                 (vn == 10'd724)                  ? e_last : 11'sd0);

    always @(posedge clk) begin
        if (rst) begin
            hc <= 0; vc <= 0; h_last <= BASE - 11'd1;
            e_frame <= 0; integ <= 0;
            since_go <= 2'd3; locked <= 1'b0; jumps <= 0;
            ph <= 0; stray <= 1'b0;
        end else if (go && (!locked || (!near && stray))) begin
            // (re)acquire: move straight to the wanted position
            vc <= TARGET; hc <= 0; h_last <= BASE - 11'd1;
            locked <= 1'b1; since_go <= 0; integ <= 0; e_frame <= 0;
            jumps <= jumps + 16'd1;
            ph <= 0; stray <= 1'b0;
        end else begin
            // A single go far from TARGET is ignored (no phase update); a
            // second one in a row re-acquires. Re-acquiring on every stray
            // go disturbed the picture several times a second on weak
            // signals.
            if (go) stray <= locked && !near;
            ph <= {ph[1:0], go && near};
            if (go) begin
                vc_go    <= vc;
                hc_go    <= hc;
                since_go <= 0;
            end
            if (ph[0]) dv   <= (dv_raw >= 11'sd375) ? dv_raw - 11'sd750 :
                               (dv_raw < -11'sd375) ? dv_raw + 11'sd750 : dv_raw;
            if (ph[1]) p_px <= dv * $signed({1'b0, BASE}) + $signed({1'b0, hc_go});
            if (ph[2]) begin
                e_frame <= e_next;           // takes effect from the next line
                integ   <= i_next;
            end
            if (hc == h_last) begin
                hc <= 0;
                h_last <= h_next[10:0];
                if (vc == V_TOTAL - 1) begin
                    vc <= 0;
                    if (since_go == 2'd3) begin
                        locked <= 1'b0; e_frame <= 0; integ <= 0;
                    end else begin
                        since_go <= since_go + 2'd1;
                    end
                end else begin
                    vc <= vc + 10'd1;
                end
            end else begin
                hc <= hc + 11'd1;
            end
        end
    end

    // Registered outputs: one pixel of latency, same for every signal.
    always @(posedge clk) begin
        x           <= hc - H_START;    // picture coordinate (0..1279 while de)
        y           <= vc;
        de          <= (hc >= H_START) && (hc < H_START + H_ACTIVE) && (vc < V_ACTIVE);
        hsync       <= (hc < H_SYNC);
        vsync       <= (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);
        frame_start <= (hc == 0) && (vc == 0);
        line_start  <= (hc == 0);
    end
endmodule
