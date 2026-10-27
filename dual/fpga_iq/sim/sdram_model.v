// Behavioural model of one W9825G6KH (16 bit, 4 banks, 8192 rows, 512 columns)
// for the subset of commands sdram_fb uses.  CL = 2, full-page bursts.
// Output data changes TAC ns after the clock edge.  Timing rules that the
// controller relies on are checked and counted in `errors`.
`timescale 1ns/1ps
module sdram_model #(
    parameter real TAC = 5.0
) (
    input  wire        clk,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    input  wire [1:0]  dqm,
    input  wire [15:0] dq_in,
    output reg  [15:0] dq_out,
    output reg         dq_drive,
    output integer     errors,
    output integer     max_ref_gap
);
    reg [15:0] mem [0:(1<<24)-1];
    reg [12:0] row  [0:3];
    reg [3:0]  open_b;
    integer    t_pre [0:3];
    integer    t_act [0:3];
    integer    cyc, t_ref, t_wlast, t_rw;
    reg        rd_on, wr_on, init_done;
    reg [1:0]  bb;
    reg [8:0]  col;
    reg [15:0] p0, p1;
    reg        v0, v1;
    integer    i;

    initial begin
        errors = 0; cyc = 0; t_ref = 0; max_ref_gap = 0; t_wlast = -10;
        open_b = 4'b0; rd_on = 0; wr_on = 0; v0 = 0; v1 = 0; init_done = 0;
        dq_drive = 0; dq_out = 16'h0;
        for (i = 0; i < 4; i = i + 1) begin t_pre[i] = -100; t_act[i] = -100; end
    end

    task err(input [8*48-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("[%0t] SDRAM: %0s", $time, msg);
        end
    endtask

    wire [2:0] c = {ras_n, cas_n, we_n};

    always @(posedge clk) begin
        cyc = cyc + 1;
        // read output pipeline (CL = 2)
        dq_out   <= #(TAC) p1;
        dq_drive <= #(TAC) v1;
        p1 = p0; v1 = v0;
        v0 = 0;

        if (!cs_n) begin
            case (c)
            3'b011: begin // ACTIVE
                if (open_b[ba]) err("ACT to open bank");
                if (cyc - t_pre[ba] < 2) err("tRP violated");
                if (cyc - t_ref < 6) err("tRFC violated");
                if (cyc - t_act[ba] < 5) err("tRC violated");
                open_b[ba] = 1'b1; row[ba] = a; t_act[ba] = cyc;
            end
            3'b101, 3'b100: begin // READ / WRITE
                if (!open_b[ba]) err("RD/WR to closed bank");
                if (cyc - t_act[ba] < 2) err("tRCD violated");
                if (a[10]) err("auto-precharge not expected");
                bb = ba; col = a[8:0];
                rd_on = (c == 3'b101); wr_on = (c == 3'b100);
            end
            3'b110: begin rd_on = 0; wr_on = 0; end // BURST STOP
            3'b010: begin // PRECHARGE
                rd_on = 0;
                if (wr_on || cyc - t_wlast < 2) begin
                    if (cyc - t_wlast < 2) err("tWR violated");
                end
                wr_on = 0;
                if (a[10]) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        if (open_b[i] && cyc - t_act[i] < 4) err("tRAS violated");
                        open_b[i] = 0; t_pre[i] = cyc;
                    end
                end else begin
                    if (open_b[ba] && cyc - t_act[ba] < 4) err("tRAS violated");
                    open_b[ba] = 0; t_pre[ba] = cyc;
                end
            end
            3'b001: begin // AUTO REFRESH
                if (open_b != 0) err("REF with open bank");
                if (init_done && cyc - t_ref > max_ref_gap) max_ref_gap = cyc - t_ref;
                t_ref = cyc;
            end
            3'b000: begin // MODE REGISTER SET
                if (a != 13'b000_0_00_010_0_111) err("unexpected mode register");
                init_done = 1;
            end
            default: ;
            endcase
        end

        if (rd_on) begin
            p0 = mem[{bb, row[bb], col}]; v0 = 1;
            col = col + 9'd1;
        end
        if (wr_on) begin
            if (dqm == 2'b00) mem[{bb, row[bb], col}] = dq_in;
            else if (dqm != 2'b11) err("partial DQM write");
            if (dqm == 2'b00) t_wlast = cyc;
            col = col + 9'd1;
        end
    end
endmodule
