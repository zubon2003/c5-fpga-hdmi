// Unit test for iq_os_rx: random 8-bit words at 40 MS/s from a clock that is
// OFFSET ppm off, with per-bit skew up to SKEW ns and edge jitter, received at
// 150 MHz.  Counts word errors after lock.
`timescale 1ns/1ps
module tb_iq_rx;
    parameter real PERIOD = 25.0025;   // +100 ppm
    parameter real SKEW   = 3.0;
    reg clk_os = 0;
    always #(10.0/3.0) clk_os = ~clk_os;
    reg rst = 1;
    initial #200 rst = 0;

    reg [7:0] val = 0;
    reg [7:0] txlog [0:262143];
    integer ntx = 0, seed = 5;
    real jit;
    initial begin
        #(7.3);
        forever begin
            jit = $dist_uniform(seed, -500, 500) / 1000.0;   // +-0.5 ns
            #(PERIOD + jit);
            val = $random(seed);
            if (ntx < 262144) txlog[ntx] = val;
            ntx = ntx + 1;
        end
    end
    wire [7:0] pin;
    genvar b;
    generate for (b = 0; b < 8; b = b + 1) begin : g
        assign #(SKEW * b / 7.0) pin[b] = val[b];
    end endgenerate

    wire       v;
    wire [7:0] d;
    wire       lock;
    iq_os_rx dut (.clk_os(clk_os), .rst_os(rst), .pin(pin), .w_valid(v), .w_data(d), .lock(lock));

    integer nrx = 0, off = -1, err = 0, k;
    reg [7:0] rxlog [0:262143];
    always @(posedge clk_os) if (v && nrx < 262144) begin rxlog[nrx] = d; nrx = nrx + 1; end

    initial begin
        #(4_000_000);
        // align on words 1000..1063
        for (k = 0; k < 40 && off < 0; k = k + 1) begin : find
            integer j, ok;
            ok = 1;
            for (j = 1000; j < 1064; j = j + 1) if (rxlog[j] !== txlog[j + k - 20]) ok = 0;
            if (ok) off = k - 20;
        end
        if (off < -20) begin $display("FAIL: no alignment"); $finish; end
        for (k = 1000; k < nrx - 10; k = k + 1) if (rxlog[k] !== txlog[k + off]) err = err + 1;
        $display("iq_os_rx: period %0.4f ns skew %0.1f ns: words rx %0d tx %0d offset %0d errors %0d lock %b",
                 PERIOD, SKEW, nrx, ntx, off, err, lock);
        $finish;
    end
endmodule
