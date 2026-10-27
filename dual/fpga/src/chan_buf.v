// Per-receiver frame storage: line buffer + triple-buffer bookkeeping.
//
// The decoder writes each active line into one of two line-buffer slots; when
// the line is complete it is copied to SDRAM (write port of sdram_fb) while
// the next line fills the other slot.
//
// Each receiver owns three field buffers in SDRAM.  A field is written into
// a buffer that is neither the last complete one nor the one the display has
// locked, so the display always reads a complete, stable field.
module chan_buf #(
    parameter [0:0] CH = 1'b0,
    parameter integer TIMEOUT = 3_000_000      // 40 ms at 75 MHz without a field
) (
    input  wire        clk,
    input  wire        rst,

    // from cvbs_decode
    input  wire        pix_we,
    input  wire [9:0]  pix_x,
    input  wire [7:0]  pix_y,
    input  wire        pix_slot,
    input  wire        line_done,
    input  wire [8:0]  line_idx,
    input  wire        field_start,
    input  wire        field_end,
    input  wire        field_par,
    input  wire        std_pal,
    input  wire [15:0] quality,

    // to sdram_fb write port
    output reg         wreq,
    output wire [21:0] wbase,
    input  wire        wack,
    input  wire [9:0]  w_idx,
    output reg  [15:0] wdata,

    // display interface
    input  wire [1:0]  lock_buf,
    input  wire        lock_valid,
    output reg         done_valid,
    output reg  [1:0]  done_buf,
    output reg         done_par,
    output reg         done_pal,
    output reg  [15:0] done_q,
    output reg         overflow
);

    // ---- line buffer: 2 slots x 1024 words, luma + neutral chroma ----
    reg [15:0] lb [0:2047];
    always @(posedge clk) begin
        if (pix_we) lb[{pix_slot, pix_x}] <= {pix_y, 8'h80};
    end

    reg        wslot;
    reg [8:0]  wline;
    always @(posedge clk) wdata <= lb[{wslot, w_idx}];

    reg [1:0]  wbuf;
    reg        writing;
    reg        end_pend;
    reg        cur_par, cur_pal;
    reg [15:0] cur_q;
    reg [21:0] tmo;

    assign wbase = {CH, wbuf, wline, 10'd0};

    // a buffer that is neither the last complete one nor the locked one
    function [1:0] pick(input [1:0] a, input av, input [1:0] b, input bv);
        begin
            if ((!av || a != 2'd0) && (!bv || b != 2'd0)) pick = 2'd0;
            else if ((!av || a != 2'd1) && (!bv || b != 2'd1)) pick = 2'd1;
            else pick = 2'd2;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            wreq <= 1'b0; writing <= 1'b0; end_pend <= 1'b0;
            done_valid <= 1'b0; done_buf <= 2'd0; done_par <= 1'b0; done_pal <= 1'b0;
            done_q <= 16'hffff; wbuf <= 2'd1; overflow <= 1'b0; tmo <= 22'd0;
            wslot <= 1'b0; wline <= 9'd0;
        end else begin
            if (tmo == TIMEOUT[21:0]) done_valid <= 1'b0;
            else tmo <= tmo + 22'd1;

            if (field_start) begin
                wbuf    <= pick(done_buf, done_valid, lock_buf, lock_valid);
                writing <= 1'b1;
                end_pend <= 1'b0;
            end

            if (wack) wreq <= 1'b0;
            if (line_done && writing) begin
                if (wreq && !wack) overflow <= 1'b1;
                wreq  <= 1'b1;
                wslot <= line_idx[0];
                wline <= line_idx;
            end

            if (field_end && writing) begin
                end_pend <= 1'b1;
                cur_par  <= field_par;
                cur_pal  <= std_pal;
                cur_q    <= quality;
            end
            if (end_pend && !wreq && !line_done) begin
                end_pend   <= 1'b0;
                writing    <= 1'b0;
                done_buf   <= wbuf;
                done_valid <= 1'b1;
                done_par   <= cur_par;
                done_pal   <= cur_pal;
                done_q     <= cur_q;
                tmo        <= 22'd0;
            end
        end
    end

endmodule
