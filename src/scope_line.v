// Waveform monitor: grabs one video line of the demodulator output per
// HDMI frame and serves it to the pixel domain.
//
// IQ domain (84.375 MHz, vid valid ~80 MS/s):
//   sync level and peak are tracked with slow decay (1 unit per 256
//   samples); the threshold is a quarter of the way up from the sync level.
//   A trigger is a drop below the threshold after >= 2400 samples (30 us)
//   above it, i.e. the start of a horizontal sync pulse. On the first
//   trigger after each arm (one per HDMI frame), 720 samples decimated by 7
//   (11.43 MS/s, 63.0 us: one NTSC line) are written to the line RAM.
// Pixel domain: rd = line RAM [x], one clock of latency.
module scope_line (
    input  wire               clk_iq,
    input  wire               rst_iq,
    input  wire               in_valid,
    input  wire signed [13:0] vid,
    input  wire               clk_pixel,
    input  wire               arm,          // pixel domain, pulse once per frame
    input  wire [9:0]         rd_addr,
    output reg  signed [13:0] rd,
    output reg                triggered     // IQ domain: a trigger in the last ~0.8 ms
);
    reg signed [13:0] ram [0:1023];
    reg [9:0]         waddr;
    reg               we;
    reg signed [13:0] wdata;

    always @(posedge clk_iq) if (we) ram[waddr] <= wdata;
    always @(posedge clk_pixel) rd <= ram[rd_addr];

    // Arm: toggle in the pixel domain, edge-detected in the IQ domain.
    reg arm_t = 1'b0;
    always @(posedge clk_pixel) if (arm) arm_t <= ~arm_t;
    reg [2:0] arm_s;
    always @(posedge clk_iq) arm_s <= {arm_s[1:0], arm_t};
    wire arm_iq = arm_s[2] ^ arm_s[1];

    reg signed [13:0] mn, mx, thr;
    reg [7:0]  decay;
    reg [11:0] above;
    reg        armed, writing;
    reg [2:0]  dec;
    reg [16:0] trig_age;

    always @(posedge clk_iq) begin
        we <= 1'b0;
        if (arm_iq) armed <= 1'b1;
        if (rst_iq) begin
            mn <= 14'sd0; mx <= 14'sd0; thr <= 14'sd0;
            above <= 0; armed <= 1'b0; writing <= 1'b0;
            trig_age <= 17'h1ffff; triggered <= 1'b0;
        end else begin
            if (trig_age != 17'h1ffff) trig_age <= trig_age + 17'd1;
            triggered <= (trig_age < 17'd65536);
            if (in_valid) begin
                decay <= decay + 8'd1;
                if (vid < mn) mn <= vid; else if (&decay) mn <= mn + 14'sd1;
                if (vid > mx) mx <= vid; else if (&decay) mx <= mx - 14'sd1;
                thr <= mn + ((mx - mn) >>> 2);

                if (vid >= thr) begin
                    if (above != 12'hfff) above <= above + 12'd1;
                end else begin
                    above <= 0;
                    if (above >= 12'd2400) begin
                        trig_age <= 0;
                        if (armed && !writing) begin
                            armed   <= 1'b0;
                            writing <= 1'b1;
                            waddr   <= 10'h3ff;     // first write wraps to 0
                            dec     <= 3'd0;
                        end
                    end
                end

                if (writing) begin
                    dec <= (dec == 3'd6) ? 3'd0 : dec + 3'd1;
                    if (dec == 3'd0) begin
                        we    <= 1'b1;
                        wdata <= vid;
                        waddr <= waddr + 10'd1;
                        if (waddr == 10'd718) writing <= 1'b0;   // this write is 719
                    end
                end
            end
        end
    end
endmodule
