// Stand-in for a XIAO ESP32-C5 running C5VRX: 6-bit composite video at
// 20 MS/s on a 40 MHz bus with every sample repeated twice (PARLIO [D,D]),
// NTSC or PAL timing with equalising / broad pulses, colour burst and a test
// picture.  Levels: sync 0, blank 20, white 60.
`timescale 1ns/1ps
module c5vrx_src #(
    parameter PAL     = 0,
    parameter PATTERN = 0,          // 0: bars + box, 1: stripes + box
    parameter real PERIOD = 25.0,   // 40 MHz bus clock
    parameter integer SEED = 1
) (
    input  wire [5:0] noise,        // peak noise in DAC codes
    input  wire       enable,
    output wire [5:0] q
);
    reg clk40 = 0;
    always #(PERIOD/2.0) clk40 = ~clk40;

    localparam integer LINE  = PAL ? 1280 : 1271;
    localparam integer HALF  = LINE / 2;
    localparam integer NLINE = PAL ? 625 : 525;
    localparam integer ACT0  = PAL ? 210 : 188;
    localparam integer ACTN  = PAL ? 1040 : 1052;
    localparam real    FSC   = PAL ? 4.43361875 : 3.579545;

    // half-line kinds
    localparam HV = 0, VS = 1, HB = 2, BS = 3, EQ = 4, BR = 5;

    function [2:0] kind(input integer l, input integer h);
        begin
            if (!PAL) begin
                if (l <= 3 || (l >= 7 && l <= 9) || (l >= 264 && l <= 265) || (l >= 270 && l <= 271)) kind = EQ;
                else if (l <= 6 || (l >= 267 && l <= 268)) kind = BR;
                else if (l <= 20 || (l >= 273 && l <= 282)) kind = h ? BS : HB;
                else if (l == 263) kind = h ? EQ : HV;
                else if (l == 266) kind = h ? BR : EQ;
                else if (l == 269) kind = h ? EQ : BR;
                else if (l == 272) kind = h ? BS : EQ;
                else if (l == 283) kind = h ? VS : HB;
                else kind = h ? VS : HV;
            end else begin
                if (l <= 2 || (l >= 314 && l <= 315)) kind = BR;
                else if (l == 3) kind = h ? EQ : BR;
                else if (l <= 5 || (l >= 310 && l <= 312) || (l >= 316 && l <= 317) || l >= 624) kind = EQ;
                else if (l == 313) kind = h ? BR : EQ;
                else if (l == 318) kind = h ? BS : EQ;
                else if (l <= 22 || (l >= 319 && l <= 335)) kind = h ? BS : HB;
                else if (l == 23) kind = h ? VS : HB;
                else if (l == 623) kind = h ? EQ : HV;
                else kind = h ? VS : HV;
            end
        end
    endfunction

    integer line = 1, smp = 0, frame = 0, rnd;
    reg     tick = 0;
    reg [5:0] val = 20;
    real    ph = 0.0;
    integer fld, row, px, y, k, chroma, v, n;

    // picture luma 0..255 at active sample px (0..ACTN-1), picture row 0..(2*field lines)
    function integer luma(input integer px, input integer row);
        integer bx, by, bar;
        begin
            bx = 100 + (frame * 12) % (ACTN - 300);
            by = 120;
            if (px < 8 || px >= ACTN - 8 || row < 4 || row >= (PAL ? 572 : 476)) luma = 255;   // border
            else if (px >= bx && px < bx + 120 && row >= by && row < by + 90) luma = 255;    // moving box
            else if (PATTERN == 0) begin
                bar = px * 8 / ACTN;
                luma = bar * 255 / 7;
                if (row >= 300 && row < 310) luma = 0;
            end else begin
                luma = ((row / 24) % 2) ? 200 : 40;
                if ((px / 66) % 2) luma = 255 - luma;
            end
        end
    endfunction

    always @(posedge clk40) begin
        tick <= ~tick;
        if (tick) begin
            // next 20 MS/s sample
            smp = smp + 1;
            if (smp == LINE) begin
                smp = 0;
                line = line + 1;
                if (line > NLINE) begin line = 1; frame = frame + 1; end
            end
            ph = ph + 2.0 * 3.14159265 * FSC / 20.0;
            if (ph > 6.2831853) ph = ph - 6.2831853;

            k = kind(line, smp >= HALF ? 1 : 0);
            n = smp >= HALF ? smp - HALF : smp;
            v = 20;
            case (k)
                EQ: v = (n < 47) ? 0 : 20;
                BR: v = (n < HALF - 94) ? 0 : 20;
                HB, HV: begin
                    if (n < 94) v = 0;
                    else if (n >= 106 && n < 156) v = 20 + $rtoi(8.0 * $sin(ph));
                    else v = 20;
                end
                default: v = 20;
            endcase
            if ((k == HV && smp >= ACT0) || (k == VS && smp < ACT0 + ACTN)) begin
                px = smp - ACT0;
                if (px >= 0 && px < ACTN) begin
                    // field 1 = lower field for NTSC, upper for PAL
                    fld = PAL ? (line < 313 ? 0 : 1) : (line < 264 ? 1 : 0);
                    if (PAL) row = 2 * (line < 313 ? line - 24 : line - 336) + fld;
                    else     row = 2 * (line < 264 ? line - 22 : line - 284) + fld;
                    y = luma(px, row);
                    chroma = (PATTERN == 0 && row < 200) ? $rtoi(6.0 * $sin(ph + (px / (ACTN / 8)) * 0.8)) : 0;
                    v = 20 + (y * 40 + 127) / 255 + chroma;
                end
            end
            if (noise != 0) begin
                rnd = $urandom % (2 * noise + 1);
                v = v + rnd - noise;
            end
            if (v < 0) v = 0;
            if (v > 63) v = 63;
            val <= enable ? v[5:0] : 6'd0;
        end
    end

    // a little bit-to-bit skew, as from different GPIO pads
    assign #(0.4) q[0] = val[0];
    assign #(1.1) q[1] = val[1];
    assign #(0.2) q[2] = val[2];
    assign #(1.6) q[3] = val[3];
    assign #(0.7) q[4] = val[4];
    assign #(1.3) q[5] = val[5];
endmodule
