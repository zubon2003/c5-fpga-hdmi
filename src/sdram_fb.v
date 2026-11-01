// Field store in the Tang SDRAM module (32 MB, 16 bit; Dock 40-pin header,
// pins as Sipeed's nestang-25k), so the HDMI output can run on a fixed,
// clean pixel clock: HDZero goggles turn white whenever the pixel clock is
// phase stepped to follow the input (video_timing.v, pclk), and re-sync on
// any line length change.
//
// IQ domain (84.375 MHz, 11.85 ns); the SDRAM clock pin is that clock
// inverted (ODDR), so commands and write data are sampled half a clock after
// they leave. CAS latency 3, burst length 1: one READ or WRITE command per
// clock to consecutive columns of an open row.
//
// Layout: 4 field buffers x 240 lines x 640 words {Y, C}; a line is two
// rows of 320 columns: row = {buf, line, half}, bank 0. Row 4095 is the
// read-timing test row.
//
// Writer: when video_in finishes an active line (ln_done, ln_idx), the line
// is copied from the 8-line input ring into the current buffer; a line
// index that does not increase starts the next buffer (with its parity).
// Reader: the pixel domain asks, once per output line, for field lines up
// to req_line (req_frame on the last line of each output frame); lines go
// into the 8-line output ring (slot = line mod 8). At req_frame the reader
// picks the buffer: the one being written if it has 6+ lines (the input
// writes its 240 lines faster than the output shows them, so the reader
// never overtakes it; a read of a line not written yet waits), else the
// last complete one. The added delay is therefore between ~0.5 ms and one
// field (16.7 ms), and steps by one field when the free-running output
// slips against the input (at 74.1818 MHz vs 59.94 Hz: every few minutes).
//
// Read timing: data is sampled at both clock edges, and one of 8 half-clock
// positions (4..11 half clocks after the READ leaves) is used. After the
// mode register is set, and on 'K' / 'k' (UART), the test row is written
// and read at each position; the middle of the passing run is used.
// status: [15] a position passed, [14] clock polarity, [13:11] position,
// [9:8] buffer distance of the last pick (0 = being written, 1 = last
// complete), [7:0] passing positions.
module sdram_fb (
    input  wire        clk,
    input  wire        rst,

    output wire        sd_clk,
    output reg         sd_cs_n,
    output reg         sd_ras_n,
    output reg         sd_cas_n,
    output reg         sd_we_n,
    output reg  [1:0]  sd_ba,
    output reg  [12:0] sd_addr,
    output wire [1:0]  sd_dqm,
    inout  wire [15:0] sd_dq,

    // input ring (written by video_in), read here
    input  wire        ln_done,        // pulse: active line ln_idx is complete
    input  wire [7:0]  ln_idx,
    input  wire        parity,         // parity of the field being written
    output reg  [12:0] ir_addr,
    input  wire [15:0] ir_data,        // one clock after ir_addr

    // output ring (read by display)
    output reg         or_we,
    output reg  [12:0] or_addr,
    output reg  [15:0] or_data,

    // requests from the pixel domain (toggle once per output line)
    input  wire        req_tg,
    input  wire        req_frame,
    input  wire [7:0]  req_line,
    output reg         rd_parity,      // parity of the buffer shown

    input  wire        recal,          // pulse: run the read timing test
    input  wire        flip_ck,        // pulse: invert the SDRAM clock, then test
    output wire [15:0] status
);
    localparam [3:0] C_MRS = 4'b0000, C_REF = 4'b0001, C_PRE = 4'b0010, C_ACT = 4'b0011,
                     C_WR  = 4'b0100, C_RD  = 4'b0101, C_NOP = 4'b0111;
    localparam [12:0] MODE = 13'h030;      // CAS latency 3, sequential, burst 1
    localparam [8:0]  NCOL = 9'd320;

    // ---- clock out ----
    reg ckpol = 1'b0;                      // 0: inverted (falls when clk rises)
    ODDR u_ck (.Q0(sd_clk), .Q1(), .D0(ckpol), .D1(~ckpol), .TX(1'b0), .CLK(clk));
    defparam u_ck.INIT = 1'b0;
    defparam u_ck.TXCLK_POL = 1'b0;

    assign sd_dqm = 2'b00;
    reg  [15:0] dq_out;
    reg         dq_oe;
    assign sd_dq = dq_oe ? dq_out : 16'bz;

    // ---- read capture: both edges, then a delay line per edge ----
    reg  [15:0] din_r, din_n, din_f;
    always @(negedge clk) din_n <= sd_dq;
    reg  [15:0] pr [0:5];
    reg  [15:0] pf [0:4];
    reg  [7:0]  tg;                        // tg[i] set after edge i of a READ (edge 0)
    integer i;
    always @(posedge clk) begin
        din_r <= sd_dq;
        din_f <= din_n;
        pr[0] <= din_r;
        pf[0] <= din_f;
        for (i = 1; i < 6; i = i + 1) pr[i] <= pr[i - 1];
        for (i = 1; i < 5; i = i + 1) pf[i] <= pf[i - 1];
    end
    // With the READ registered at edge 0: din_r after edge k holds the
    // sample of edge k (half-clock position 2k), din_f after edge k + 1
    // that of the falling edge before (2k + 1); pr[j] / pf[j] are those
    // delayed j + 1 clocks. After edge 7 (used at edge 8, with tg[7])
    // position p = sel + 4 is in pr[4 - sel / 2] (even) or pf[(7 - sel) / 2]
    // (odd).
    reg  [2:0]  sel = 3'd3;
    reg  [15:0] dsel;
    always @(*) begin
        case (sel)
            3'd0: dsel = pr[4];
            3'd1: dsel = pf[3];
            3'd2: dsel = pr[3];
            3'd3: dsel = pf[2];
            3'd4: dsel = pr[2];
            3'd5: dsel = pf[1];
            3'd6: dsel = pr[1];
            default: dsel = pf[0];
        endcase
    end

    // ---- jobs ----
    reg  [1:0]  wr_buf;
    reg  [8:0]  wr_cnt;                    // lines of wr_buf in the SDRAM
    reg  [7:0]  last_idx;
    reg  [3:0]  buf_par;
    reg         wj_pend;
    reg  [7:0]  wj_line;
    reg  [1:0]  wj_buf;

    reg  [2:0]  rq_s;
    reg         rq_new;
    reg  [7:0]  rd_need;
    reg  [8:0]  rd_next;                   // next line to read (240 = done)
    reg  [1:0]  rd_buf;
    reg  [1:0]  pick_d;

    // ---- controller ----
    localparam [3:0] S_INIT = 4'd0, S_PRE0 = 4'd1, S_REF0 = 4'd2, S_MRS = 4'd3,
                     S_IDLE = 4'd4, S_ACT = 4'd5, S_GAP = 4'd6, S_RW = 4'd7,
                     S_TAIL = 4'd8, S_PRE = 4'd9, S_RP = 4'd10, S_REF = 4'd11,
                     S_CAL = 4'd12;
    reg  [3:0]  st;
    reg  [14:0] cnt;
    reg  [3:0]  nref;
    reg  [8:0]  col;
    reg         op_wr, op_cal, op_half;
    reg  [10:0] op_row;                    // {buf, line, half}
    reg  [7:0]  op_line;
    reg  [1:0]  op_buf;
    reg  [9:0]  ref_t;
    reg  [3:0]  ref_debt;
    // calibration: 0 idle, 1 write test row, 2 read at sel, 3 next
    reg  [1:0]  cal_st;
    reg  [7:0]  pass;
    reg         cal_ok;
    reg  [15:0] errs;

    function [3:0] pick(input [7:0] m);     // {found, middle of the first run}
        integer k;
        reg found, done;
        reg [3:0] f, l, s;
        begin
            found = 1'b0; done = 1'b0; f = 0; l = 0;
            for (k = 0; k < 8; k = k + 1) begin
                if (m[k] && !done) begin
                    if (!found) begin found = 1'b1; f = k; end
                    l = k;
                end else if (found) done = 1'b1;
            end
            s = (f + l) >> 1;
            pick = {found, s[2:0]};
        end
    endfunction
    wire [3:0] pk = pick(pass);

    function [15:0] pattern(input [8:0] c);
        pattern = {c[7:0] ^ 8'h3c, ~c[7:0] ^ {7'd0, c[8]}};
    endfunction

    // input ring base: slot * 640 + half * 320
    wire [2:0]  w_slot  = wj_line[2:0];
    wire [12:0] ir_base = {w_slot, 9'd0} + {w_slot, 7'd0};
    wire [2:0]  r_slot  = rd_next[2:0];
    wire [12:0] or_base = {r_slot, 9'd0} + {r_slot, 7'd0};
    wire [12:0] op_base = {op_line[2:0], 9'd0} + {op_line[2:0], 7'd0};

    wire rd_ready = (rd_next <= {1'b0, rd_need}) && (rd_next < 9'd240) &&
                    (rd_buf != wr_buf || rd_next < wr_cnt);

    // pick at the output frame start: being written if 6+ lines are in
    wire [1:0] rd_pick = (wr_cnt >= 9'd6) ? wr_buf : wr_buf - 2'd1;

    reg [12:0] or_ptr;
    always @(posedge clk) begin
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_NOP;
        or_we <= 1'b0;

        // requests from the pixel domain
        rq_s   <= {rq_s[1:0], req_tg};
        rq_new <= rq_s[2] ^ rq_s[1];
        if (rq_new) begin
            rd_need <= req_line;
            if (req_frame) begin
                rd_buf    <= rd_pick;
                pick_d    <= wr_buf - rd_pick;
                rd_parity <= buf_par[rd_pick];
                rd_next   <= 9'd0;
            end
        end

        // lines from video_in
        if (ln_done) begin
            wj_pend <= 1'b1;
            wj_line <= ln_idx;
            last_idx <= ln_idx;
            if (ln_idx <= last_idx) begin
                wr_buf  <= wr_buf + 2'd1;
                wj_buf  <= wr_buf + 2'd1;
                wr_cnt  <= 9'd0;
                buf_par[wr_buf + 2'd1] <= parity;
            end else begin
                wj_buf  <= wr_buf;
            end
        end

        // refresh: one due every 512 clocks (6.1 us)
        ref_t <= ref_t + 10'd1;
        if (ref_t[8:0] == 9'd511 && ref_debt != 4'hf) ref_debt <= ref_debt + 4'd1;

        // read data pipeline
        tg <= {tg[6:0], 1'b0};
        if (tg[7]) begin
            if (op_cal) begin
                if (dsel != pattern(or_ptr[8:0])) errs <= errs + 16'd1;
            end else begin
                or_we   <= 1'b1;
                or_addr <= or_ptr;
                or_data <= dsel;
            end
            or_ptr <= or_ptr + 13'd1;
        end

        case (st)
            S_INIT: begin                   // 200 us after power-up
                cnt <= cnt + 15'd1;
                if (cnt == 15'd20000) begin
                    {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_PRE;
                    sd_addr[10] <= 1'b1;    // all banks
                    cnt <= 0; nref <= 0;
                    st  <= S_PRE0;
                end
            end
            S_PRE0: begin
                cnt <= cnt + 15'd1;
                if (cnt == 15'd3) begin cnt <= 0; st <= S_REF0; end
            end
            S_REF0: begin                   // 8 refreshes, 8 clocks apart
                cnt <= cnt + 15'd1;
                if (cnt == 15'd0) {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_REF;
                if (cnt == 15'd9) begin
                    cnt  <= 0;
                    nref <= nref + 4'd1;
                    if (nref == 4'd7) begin
                        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_MRS;
                        sd_addr <= MODE;
                        sd_ba   <= 2'b00;
                        st <= S_MRS;
                    end
                end
            end
            S_MRS: begin
                cnt <= cnt + 15'd1;
                if (cnt == 15'd3) begin cnt <= 0; cal_st <= 2'd1; st <= S_IDLE; end
            end

            S_IDLE: begin
                cnt <= 0;
                col <= 0;
                op_cal <= 1'b0;
                if (ref_debt != 0) begin
                    {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_REF;
                    ref_debt <= ref_debt - 4'd1;
                    st <= S_REF;
                end else if (cal_st == 2'd1) begin          // write the test row
                    op_wr <= 1'b1; op_cal <= 1'b1; op_half <= 1'b0;
                    op_row <= 11'd0; pass <= 0; sel <= 0;
                    st <= S_ACT;
                end else if (cal_st == 2'd2) begin          // read it at sel
                    op_wr <= 1'b0; op_cal <= 1'b1; op_half <= 1'b0;
                    errs <= 0; or_ptr <= 0;
                    st <= S_ACT;
                end else if (wj_pend) begin
                    wj_pend <= 1'b0;
                    op_wr <= 1'b1; op_half <= 1'b0;
                    op_buf <= wj_buf; op_line <= wj_line;
                    op_row <= {wj_buf, wj_line, 1'b0};
                    ir_addr <= ir_base;
                    st <= S_ACT;
                end else if (rd_ready) begin
                    op_wr <= 1'b0; op_half <= 1'b0;
                    op_buf <= rd_buf; op_line <= rd_next[7:0];
                    op_row <= {rd_buf, rd_next[7:0], 1'b0};
                    or_ptr <= or_base;
                    rd_next <= rd_next + 9'd1;
                    st <= S_ACT;
                end
            end
            S_ACT: begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_ACT;
                sd_ba   <= 2'b00;
                sd_addr <= op_cal ? 13'd4095 : {2'b00, op_row};
                st <= S_GAP;
            end
            S_GAP: begin                    // tRCD = 2 clocks
                ir_addr <= ir_addr + 13'd1;
                st <= S_RW;
            end
            S_RW: begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= op_wr ? C_WR : C_RD;
                sd_addr <= {4'b0000, col};
                dq_out  <= op_cal ? pattern(col) : ir_data;
                dq_oe   <= op_wr;
                tg[0]   <= !op_wr;
                ir_addr <= ir_addr + 13'd1;
                col     <= col + 9'd1;
                if (col == NCOL - 9'd1) st <= S_TAIL;
            end
            S_TAIL: begin                   // write recovery / read data out
                dq_oe <= 1'b0;
                cnt   <= cnt + 15'd1;
                if (cnt == 15'd10) begin
                    {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_PRE;
                    sd_addr[10] <= 1'b1;
                    cnt <= 0;
                    st  <= S_RP;
                end
            end
            S_RP: begin                     // tRP, then the second half or done
                cnt <= cnt + 15'd1;
                if (cnt == 15'd2) begin
                    cnt <= 0;
                    col <= 0;
                    if (op_cal) begin
                        st <= S_CAL;
                    end else if (!op_half) begin
                        op_half <= 1'b1;
                        op_row  <= {op_buf, op_line, 1'b1};
                        if (op_wr) ir_addr <= op_base + 13'd320;
                        else       or_ptr  <= op_base + 13'd320;
                        st <= S_ACT;
                    end else begin
                        if (op_wr && op_buf == wr_buf && !(ln_done && ln_idx <= last_idx))
                            wr_cnt <= {1'b0, op_line} + 9'd1;
                        st <= S_IDLE;
                    end
                end
            end
            S_CAL: begin
                st <= S_IDLE;
                if (cal_st == 2'd1) begin
                    cal_st <= 2'd2;
                end else begin
                    pass[sel] <= (errs == 0);
                    if (sel == 3'd7) cal_st <= 2'd3;
                    else             sel <= sel + 3'd1;
                end
            end
            S_REF: begin                    // tRFC: 8 clocks
                cnt <= cnt + 15'd1;
                if (cnt == 15'd8) begin cnt <= 0; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
        endcase

        // calibration result
        if (cal_st == 2'd3) begin
            cal_st <= 2'd0;
            cal_ok <= pk[3];
            sel    <= pk[3] ? pk[2:0] : 3'd3;
        end
        if (st >= S_IDLE && cal_st == 2'd0) begin
            if (recal) cal_st <= 2'd1;
            if (flip_ck) begin ckpol <= ~ckpol; cal_st <= 2'd1; end
        end

        if (rst) begin
            st <= S_INIT; cnt <= 0; dq_oe <= 1'b0; tg <= 0;
            cal_st <= 2'd0; cal_ok <= 1'b0; pass <= 0; sel <= 3'd3;
            wr_buf <= 0; wr_cnt <= 0; last_idx <= 8'd255; buf_par <= 0;
            wj_pend <= 1'b0; rd_buf <= 0; rd_next <= 9'd240; rd_need <= 0;
            ref_t <= 0; ref_debt <= 0; rd_parity <= 1'b0; pick_d <= 0;
            sd_cs_n <= 1'b1;
        end
    end

    assign status = {cal_ok, ckpol, sel, 1'b0, pick_d, pass};
endmodule
