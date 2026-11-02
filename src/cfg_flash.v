// Settings kept in the configuration flash (Tang Primer 25K: 64 Mbit SPI
// NOR on the MSPI pins, usable as user I/O after configuration with
// -use_mspi_as_gpio; the bitstream ends at ~0x0E3000).
//
// One 8-byte record at ADDR, the last 4 KB sector: bytes 0..5 = the 'R'
// settings bytes 0..5 (top.v), byte 6 = 0x5A, byte 7 = ~(sum of bytes
// 0..6). After reset the record is read once; if it checks out, `load`
// pulses with its settings, otherwise the power-up values stay. When the
// settings differ from the stored ones and have not changed for 2 s, the
// sector is erased, the record programmed and read back.
//
// SPI mode 0, 10.5 MHz (HALF = 4 clocks per half period). A power cut
// while saving leaves an erased or partial record, which fails the check:
// the next power-up uses the power-up values.
//
// status: [0] loaded at power-up, [1] no valid record at power-up,
// [2] saving, [3] last save read back OK, [4] last save failed (read back
// differs or erase / program time-out), [7:5] saves (wraps).
module cfg_flash #(
    parameter        CLK_HZ = 84375000,
    parameter [23:0] ADDR   = 24'h7FF000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [47:0] cur,          // live settings ('R' bytes 0..5)
    output reg         load,         // one clock: apply load_data
    output reg  [47:0] load_data,
    output wire [7:0]  status,
    output reg         f_cs_n,
    output reg         f_clk,
    output reg         f_mosi,
    input  wire        f_miso
);
    localparam        HALF     = 4;
    localparam [27:0] T_BOOT   = CLK_HZ / 1000;     // 1 ms after reset
    localparam [27:0] T_RES    = CLK_HZ / 20000;    // 50 us after 0xAB
    localparam [27:0] T_SETTLE = CLK_HZ * 2;
    localparam [27:0] T_BUSY   = CLK_HZ * 3;        // 4 KB erase is < 0.5 s

    localparam [2:0] O_RES = 3'd0, O_READ = 3'd1, O_WREN = 3'd2,
                     O_ERASE = 3'd3, O_RDSR = 3'd4, O_PP = 3'd5;

    // record byte 7 for bytes 0..6
    function [7:0] chk(input [55:0] d);
        chk = ~(d[7:0] + d[15:8] + d[23:16] + d[31:24] + d[39:32] + d[47:40] + d[55:48]);
    endfunction

    reg [63:0] rec;                   // record being written
    reg [63:0] rdbuf;                 // record read back (byte 0 in [7:0])
    reg [7:0]  sr;                    // status register (RDSR)

    // byte i of a transaction; d = i - 4 (record byte for O_PP)
    function [7:0] txb(input [2:0] o, input [3:0] i, input [63:0] r, input [3:0] d);
        case (i)
            4'd0: case (o)
                      O_RES:   txb = 8'hAB;
                      O_READ:  txb = 8'h03;
                      O_WREN:  txb = 8'h06;
                      O_ERASE: txb = 8'h20;
                      O_RDSR:  txb = 8'h05;
                      default: txb = 8'h02;
                  endcase
            4'd1: txb = (o == O_RDSR) ? 8'h00 : ADDR[23:16];
            4'd2: txb = ADDR[15:8];
            4'd3: txb = ADDR[7:0];
            default: txb = (o == O_PP) ? r[{d[2:0], 3'b000} +: 8] : 8'h00;
        endcase
    endfunction
    function [3:0] oplen(input [2:0] o);
        case (o)
            O_READ, O_PP: oplen = 4'd12;
            O_ERASE:      oplen = 4'd4;
            O_RDSR:       oplen = 4'd2;
            default:      oplen = 4'd1;
        endcase
    endfunction

    localparam [4:0] M_BOOT = 5'd0, M_RESW = 5'd1, M_LOADED = 5'd2, M_IDLE = 5'd3,
                     M_ERASE = 5'd4, M_EW = 5'd5, M_EP = 5'd6, M_WREN2 = 5'd7,
                     M_PP = 5'd8, M_PW = 5'd9, M_PP2 = 5'd10, M_VFY = 5'd11,
                     M_FAIL = 5'd12,
                     E_START = 5'd16, E_LOW = 5'd17, E_HIGH = 5'd18, E_END = 5'd19,
                     E_GAP = 5'd20;
    reg [4:0]  st = M_BOOT, ret;
    reg [2:0]  op;
    reg [3:0]  idx;
    reg [7:0]  sh, rx;
    reg [2:0]  bitn;
    reg [3:0]  hc;
    reg [27:0] tm;
    reg [47:0] saved, last;
    reg [27:0] still;                 // clocks the settings have been unchanged
    reg        s_loaded, s_none, s_busy, s_ok, s_fail;
    reg [2:0]  s_saves;
    assign status = {s_saves, s_fail, s_ok, s_busy, s_none, s_loaded};

    always @(posedge clk) begin
        load <= 1'b0;
        if (tm != {28{1'b1}}) tm <= tm + 28'd1;
        last <= cur;
        if (rst) begin
            st       <= M_BOOT;
            tm       <= 28'd0;
            f_cs_n   <= 1'b1;
            f_clk    <= 1'b0;
            f_mosi   <= 1'b0;
            s_loaded <= 1'b0;
            s_none   <= 1'b0;
            s_busy   <= 1'b0;
            s_ok     <= 1'b0;
            s_fail   <= 1'b0;
            s_saves  <= 3'd0;
            still    <= 28'd0;
        end else case (st)
            M_BOOT: if (tm >= T_BOOT) begin
                op <= O_RES; ret <= M_RESW; st <= E_START;
            end
            M_RESW: if (tm >= T_RES) begin
                op <= O_READ; ret <= M_LOADED; st <= E_START;
            end
            M_LOADED: begin
                if (rdbuf[55:48] == 8'h5A && rdbuf[63:56] == chk(rdbuf[55:0])) begin
                    load      <= 1'b1;
                    load_data <= rdbuf[47:0];
                    saved     <= rdbuf[47:0];
                    s_loaded  <= 1'b1;
                end else begin
                    saved     <= cur;
                    s_none    <= 1'b1;
                end
                still <= 28'd0;
                st    <= M_IDLE;
            end
            M_IDLE: begin
                if (cur != last || cur == saved) still <= 28'd0;
                else if (still != T_SETTLE) still <= still + 28'd1;
                else begin
                    rec    <= {chk({8'h5A, cur}), 8'h5A, cur};
                    s_busy <= 1'b1;
                    op     <= O_WREN; ret <= M_ERASE; st <= E_START;
                end
            end
            M_ERASE: begin op <= O_ERASE; ret <= M_EW; st <= E_START; end
            M_EW:    begin tm <= 28'd0; op <= O_RDSR; ret <= M_EP; st <= E_START; end
            M_EP:    if (!sr[0])            begin op <= O_WREN; ret <= M_PP; st <= E_START; end
                     else if (tm >= T_BUSY) st <= M_FAIL;
                     else                   begin op <= O_RDSR; ret <= M_EP; st <= E_START; end
            M_PP:    begin op <= O_PP; ret <= M_PW; st <= E_START; end
            M_PW:    begin tm <= 28'd0; op <= O_RDSR; ret <= M_PP2; st <= E_START; end
            M_PP2:   if (!sr[0])            begin op <= O_READ; ret <= M_VFY; st <= E_START; end
                     else if (tm >= T_BUSY) st <= M_FAIL;
                     else                   begin op <= O_RDSR; ret <= M_PP2; st <= E_START; end
            M_VFY: begin
                // not retried on a failure, so a bad flash is not worn out
                saved   <= rec[47:0];
                s_busy  <= 1'b0;
                s_ok    <= (rdbuf == rec);
                s_fail  <= (rdbuf != rec);
                s_saves <= s_saves + 3'd1;
                still   <= 28'd0;
                st      <= M_IDLE;
            end
            M_FAIL: begin
                saved   <= rec[47:0];
                s_busy  <= 1'b0;
                s_ok    <= 1'b0;
                s_fail  <= 1'b1;
                s_saves <= s_saves + 3'd1;
                still   <= 28'd0;
                st      <= M_IDLE;
            end

            // ---- one transaction: CS low, oplen(op) bytes, CS high ----
            E_START: begin
                f_cs_n <= 1'b0;
                f_clk  <= 1'b0;
                idx    <= 4'd0;
                bitn   <= 3'd0;
                sh     <= txb(op, 4'd0, rec, 4'd0);
                f_mosi <= txb(op, 4'd0, rec, 4'd0) >> 7;
                hc     <= 4'd0;
                st     <= E_LOW;
            end
            E_LOW: if (hc == HALF - 1) begin       // rising edge: sample MISO
                hc    <= 4'd0;
                f_clk <= 1'b1;
                rx    <= {rx[6:0], f_miso};
                st    <= E_HIGH;
            end else hc <= hc + 4'd1;
            E_HIGH: if (hc == HALF - 1) begin      // falling edge: next bit out
                hc    <= 4'd0;
                f_clk <= 1'b0;
                if (bitn == 3'd7) begin
                    if (op == O_READ && idx >= 4'd4) rdbuf <= {rx, rdbuf[63:8]};
                    if (op == O_RDSR && idx == 4'd1) sr    <= rx;
                    if (idx == oplen(op) - 4'd1) st <= E_END;
                    else begin
                        idx    <= idx + 4'd1;
                        bitn   <= 3'd0;
                        sh     <= txb(op, idx + 4'd1, rec, idx - 4'd3);
                        f_mosi <= txb(op, idx + 4'd1, rec, idx - 4'd3) >> 7;
                        st     <= E_LOW;
                    end
                end else begin
                    bitn   <= bitn + 3'd1;
                    sh     <= sh << 1;
                    f_mosi <= sh[6];
                    st     <= E_LOW;
                end
            end else hc <= hc + 4'd1;
            E_END: if (hc == HALF - 1) begin
                hc     <= 4'd0;
                f_cs_n <= 1'b1;
                st     <= E_GAP;
            end else hc <= hc + 4'd1;
            E_GAP: if (hc == 4'd15) begin          // CS high >= 100 ns
                hc <= 4'd0;
                if (ret == M_RESW) tm <= 28'd0;
                st <= ret;
            end else hc <= hc + 4'd1;
            default: st <= M_BOOT;
        endcase
    end
endmodule
