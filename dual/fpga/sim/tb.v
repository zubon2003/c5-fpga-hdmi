// System testbench: two simulated C5VRX receivers -> c5vrx_core -> SDRAM model.
// Writes selected output frames as PPM images and checks the TMDS encoding by
// decoding it again.
`timescale 1ns/1ps
module tb;
    reg clk_os = 0, clk = 0;
    always #(10.0/3.0)  clk_os = ~clk_os;     // 150 MHz
    always #(20.0/3.0)  clk    = ~clk;        // 75 MHz
    reg rst = 1, rst_os = 1;
    initial begin
        #2000 rst = 0;
        #1    rst_os = 0;
    end

    // scenario controls
    reg [5:0] noise_a = 1, noise_b = 12;
    reg       en_a = 1, en_b = 1;
    reg       btn = 0;
    integer   STOP_MS;
    integer   PAL_A, PAL_B;

    wire [5:0] xa, xb;
`ifdef PAL_B_SRC
    c5vrx_src #(.PAL(1), .PATTERN(1), .PERIOD(24.9996)) src_b (.noise(noise_b), .enable(en_b), .q(xb));
`else
    c5vrx_src #(.PAL(0), .PATTERN(1), .PERIOD(24.9996)) src_b (.noise(noise_b), .enable(en_b), .q(xb));
`endif
    c5vrx_src #(.PAL(0), .PATTERN(0), .PERIOD(25.0003)) src_a (.noise(noise_a), .enable(en_a), .q(xa));

    wire        cs_n, ras_n, cas_n, we_n, dq_oe, drive;
    wire [12:0] a;
    wire [1:0]  ba, dqm;
    wire [15:0] dq_o, dq_m;
    wire [9:0]  t_r, t_g, t_b;
    wire [7:0]  vr, vg, vb;
    wire        de, hs, vs, dual, sel;
    wire [1:0]  rxv, ovf;
    integer     sd_err, ref_gap;

    c5vrx_core dut (
        .clk_os(clk_os), .rst_os(rst_os), .clk(clk), .rst(rst),
        .xa_cvbs(xa), .xb_cvbs(xb), .btn_mode(btn),
        .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
        .sd_a(a), .sd_ba(ba), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe),
        .sd_dq_i(drive ? dq_m : 16'hdead),
        .tmds_r(t_r), .tmds_g(t_g), .tmds_b(t_b),
        .vid_r(vr), .vid_g(vg), .vid_b(vb), .vid_de(de), .vid_hs(hs), .vid_vs(vs),
        .mode_dual(dual), .sel_ch(sel), .rx_valid(rxv), .rx_overflow(ovf));

    sdram_model sdram (.clk(~clk), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .a(a), .ba(ba), .dqm(dqm), .dq_in(dq_o), .dq_out(dq_m), .dq_drive(drive),
        .errors(sd_err), .max_ref_gap(ref_gap));

    // ---------------- frame capture ----------------
    integer frame = 0, x = 0, y = 0, fd = 0, dumped = 0;
    reg     vs_d = 0, de_d = 0;
    reg [8*64-1:0] fname;
    integer dump_list [0:15];
    integer ndump = 0, k;
    function want(input integer f);
        integer i;
        begin
            want = 0;
            for (i = 0; i < ndump; i = i + 1) if (dump_list[i] == f) want = 1;
        end
    endfunction

    always @(posedge clk) begin
        vs_d <= vs;
        de_d <= de;
        if (vs && !vs_d) begin
            if (fd != 0) begin $fclose(fd); fd = 0; end
            frame = frame + 1;
            y = 0;
            $display("[%0.3f ms] frame %0d  dual=%0d sel=%0d valid=%b ovf=%b qA=%0d qB=%0d sd_err=%0d",
                     $realtime / 1e6, frame, dual, sel, rxv, ovf,
                     dut.u_bufa.done_q, dut.u_bufb.done_q, sd_err);
            if (want(frame)) begin
                $sformat(fname, "frame_%03d.ppm", frame);
                fd = $fopen(fname, "wb");
                $fwrite(fd, "P6\n1280 720\n255\n");
            end
        end
        if (de) begin
            if (fd != 0) $fwrite(fd, "%c%c%c", vr, vg, vb);
            x = x + 1;
        end
        if (!de && de_d) begin
            if (x != 1280) $display("ERROR: line with %0d pixels", x);
            x = 0;
            y = y + 1;
        end
    end

    // ---------------- TMDS check ----------------
    reg [7:0] er, eg, eb;
    reg       ede, ehs, evs;
    integer   tmds_err = 0, tmds_cnt = 0;
    integer   disp = 0;
    function [7:0] dec(input [9:0] q);
        reg [7:0] t;
        integer i;
        begin
            t = q[9] ? ~q[7:0] : q[7:0];
            dec[0] = t[0];
            for (i = 1; i < 8; i = i + 1) dec[i] = q[8] ? (t[i] ^ t[i-1]) : ~(t[i] ^ t[i-1]);
        end
    endfunction
    function integer ones(input [9:0] q);
        integer i;
        begin ones = 0; for (i = 0; i < 10; i = i + 1) ones = ones + q[i]; end
    endfunction
    always @(posedge clk) begin
        {er, eg, eb, ede, ehs, evs} <= {vr, vg, vb, de, hs, vs};
        if (!rst && frame >= 1) begin
            if (ede) begin
                tmds_cnt = tmds_cnt + 1;
                if (dec(t_r) != er || dec(t_g) != eg || dec(t_b) != eb) tmds_err = tmds_err + 1;
                disp = disp + ones(t_r) - 5;
            end else begin
                case (t_b)
                    10'b1101010100: if ({evs, ehs} != 2'b00) tmds_err = tmds_err + 1;
                    10'b0010101011: if ({evs, ehs} != 2'b01) tmds_err = tmds_err + 1;
                    10'b0101010100: if ({evs, ehs} != 2'b10) tmds_err = tmds_err + 1;
                    10'b1010101011: if ({evs, ehs} != 2'b11) tmds_err = tmds_err + 1;
                    default: tmds_err = tmds_err + 1;
                endcase
            end
        end
    end

    // ---------------- scenario ----------------
    initial begin
        if (!$value$plusargs("stop_ms=%d", STOP_MS)) STOP_MS = 235;
        // frames to dump
        dump_list[0] = 9;  dump_list[1] = 11; dump_list[2] = 13; ndump = 3;
        if ($test$plusargs("dualfirst")) begin
            #(1000) btn = 1; #(6_000_000) btn = 0;
        end
        // ~140 ms: receiver A gets noisy, B gets clean -> diversity should switch
        #(140_000_000);
        noise_a = 14; noise_b = 1;
        #(40_000_000);
        // ~180 ms: press S1 -> dual view
        btn = 1; #(6_000_000) btn = 0;
    end
    initial begin
        #(1);
        wait (STOP_MS > 0);
        #(STOP_MS * 1_000_000.0);
        $display("END  frames=%0d tmds_checked=%0d tmds_err=%0d red_disparity=%0d sdram_err=%0d max_ref_gap=%0d",
                 frame, tmds_cnt, tmds_err, disp, sd_err, ref_gap);
        $finish;
    end
endmodule
