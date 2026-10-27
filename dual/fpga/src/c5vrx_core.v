// Everything except clocking and Gowin I/O primitives (so it simulates as is).
//
//   XIAO-A, XIAO-B --cvbs_os_rx (150 MHz)--> cvbs_decode --> chan_buf --+
//                                                                       |
//                       sdram_fb (SDRAM, three field buffers per receiver)
//                                                                       |
//   HDMI <-- tmds_enc <-- display (720p, diversity / dual, S1 toggles) <-+
module c5vrx_core (
    input  wire        clk_os,       // 150 MHz oversampling clock
    input  wire        rst_os,
    input  wire        clk,          // 75 MHz system / pixel clock
    input  wire        rst,

    input  wire [5:0]  xa_cvbs,
    input  wire [5:0]  xb_cvbs,
    input  wire        btn_mode,     // S1, active high

    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [12:0] sd_a,
    output wire [1:0]  sd_ba,
    output wire [1:0]  sd_dqm,
    output wire [15:0] sd_dq_o,
    output wire        sd_dq_oe,
    input  wire [15:0] sd_dq_i,

    output wire [9:0]  tmds_r,
    output wire [9:0]  tmds_g,
    output wire [9:0]  tmds_b,

    // debug / simulation taps
    output wire [7:0]  vid_r,
    output wire [7:0]  vid_g,
    output wire [7:0]  vid_b,
    output wire        vid_de,
    output wire        vid_hs,
    output wire        vid_vs,
    output wire        mode_dual,
    output wire        sel_ch,
    output wire [1:0]  rx_valid,
    output wire [1:0]  rx_overflow
);

    // ---------------- receivers ----------------
    wire       sa_v, sb_v;
    wire [5:0] sa_d, sb_d;
    cvbs_os_rx u_rxa (.clk_os(clk_os), .rst_os(rst_os), .pin(xa_cvbs),
                      .clk_sys(clk), .rst_sys(rst), .s_valid(sa_v), .s_data(sa_d));
    cvbs_os_rx u_rxb (.clk_os(clk_os), .rst_os(rst_os), .pin(xb_cvbs),
                      .clk_sys(clk), .rst_sys(rst), .s_valid(sb_v), .s_data(sb_d));

    wire       a_pwe, b_pwe, a_slot, b_slot, a_ld, b_ld, a_fs, b_fs, a_fe, b_fe;
    wire       a_par, b_par, a_pal, b_pal;
    wire [9:0] a_px, b_px;
    wire [7:0] a_py, b_py;
    wire [8:0] a_li, b_li;
    wire [15:0] a_q, b_q;

    cvbs_decode u_deca (.clk(clk), .rst(rst), .s_valid(sa_v), .s(sa_d),
        .pix_we(a_pwe), .pix_x(a_px), .pix_y(a_py), .pix_slot(a_slot),
        .line_done(a_ld), .line_idx(a_li), .field_start(a_fs), .field_end(a_fe),
        .field_par(a_par), .std_pal(a_pal), .quality(a_q));
    cvbs_decode u_decb (.clk(clk), .rst(rst), .s_valid(sb_v), .s(sb_d),
        .pix_we(b_pwe), .pix_x(b_px), .pix_y(b_py), .pix_slot(b_slot),
        .line_done(b_ld), .line_idx(b_li), .field_start(b_fs), .field_end(b_fe),
        .field_par(b_par), .std_pal(b_pal), .quality(b_q));

    // ---------------- frame buffers ----------------
    wire        a_wreq, b_wreq, a_wack, b_wack;
    wire [21:0] a_wbase, b_wbase;
    wire [15:0] a_wdata, b_wdata;
    wire [9:0]  w_idx;
    wire [3:0]  lock_buf;
    wire [1:0]  lock_valid;
    wire        a_dv, b_dv, a_dpar, b_dpar, a_dpal, b_dpal;
    wire [1:0]  a_dbuf, b_dbuf;
    wire [15:0] a_dq, b_dq;

    chan_buf #(.CH(1'b0)) u_bufa (.clk(clk), .rst(rst),
        .pix_we(a_pwe), .pix_x(a_px), .pix_y(a_py), .pix_slot(a_slot),
        .line_done(a_ld), .line_idx(a_li), .field_start(a_fs), .field_end(a_fe),
        .field_par(a_par), .std_pal(a_pal), .quality(a_q),
        .wreq(a_wreq), .wbase(a_wbase), .wack(a_wack), .w_idx(w_idx), .wdata(a_wdata),
        .lock_buf(lock_buf[1:0]), .lock_valid(lock_valid[0]),
        .done_valid(a_dv), .done_buf(a_dbuf), .done_par(a_dpar), .done_pal(a_dpal),
        .done_q(a_dq), .overflow(rx_overflow[0]));
    chan_buf #(.CH(1'b1)) u_bufb (.clk(clk), .rst(rst),
        .pix_we(b_pwe), .pix_x(b_px), .pix_y(b_py), .pix_slot(b_slot),
        .line_done(b_ld), .line_idx(b_li), .field_start(b_fs), .field_end(b_fe),
        .field_par(b_par), .std_pal(b_pal), .quality(b_q),
        .wreq(b_wreq), .wbase(b_wbase), .wack(b_wack), .w_idx(w_idx), .wdata(b_wdata),
        .lock_buf(lock_buf[3:2]), .lock_valid(lock_valid[1]),
        .done_valid(b_dv), .done_buf(b_dbuf), .done_par(b_dpar), .done_pal(b_dpal),
        .done_q(b_dq), .overflow(rx_overflow[1]));

    wire        r_req, r_take, r_ack, r_we;
    wire [21:0] r_base;
    wire [9:0]  r_idx;
    wire [15:0] r_data;

    sdram_fb u_sdram (.clk(clk), .rst(rst),
        .w0_req(a_wreq), .w0_base(a_wbase), .w0_ack(a_wack), .w0_data(a_wdata),
        .w1_req(b_wreq), .w1_base(b_wbase), .w1_ack(b_wack), .w1_data(b_wdata),
        .w_idx(w_idx),
        .r_req(r_req), .r_base(r_base), .r_take(r_take), .r_ack(r_ack),
        .r_we(r_we), .r_idx(r_idx), .r_data(r_data),
        .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i));

    // ---------------- display ----------------
    wire press;
    reg  dual_r;
    button u_btn (.clk(clk), .rst(rst), .btn(btn_mode), .press(press));
    always @(posedge clk) begin
        if (rst) dual_r <= 1'b0;
        else if (press) dual_r <= ~dual_r;
    end
    assign mode_dual = dual_r;
    assign rx_valid  = {b_dv, a_dv};

    display u_disp (.clk(clk), .rst(rst), .mode_dual(dual_r),
        .done_valid({b_dv, a_dv}), .done_buf({b_dbuf, a_dbuf}), .done_par({b_dpar, a_dpar}),
        .done_pal({b_dpal, a_dpal}), .done_q({b_dq, a_dq}),
        .lock_buf(lock_buf), .lock_valid(lock_valid), .sel_ch(sel_ch),
        .r_req(r_req), .r_base(r_base), .r_take(r_take), .r_ack(r_ack),
        .r_we(r_we), .r_idx(r_idx), .r_data(r_data),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs));

    tmds_enc u_enc_b (.clk(clk), .rst(rst), .d(vid_b), .c({vid_vs, vid_hs}), .de(vid_de), .q(tmds_b));
    tmds_enc u_enc_g (.clk(clk), .rst(rst), .d(vid_g), .c(2'b00),            .de(vid_de), .q(tmds_g));
    tmds_enc u_enc_r (.clk(clk), .rst(rst), .d(vid_r), .c(2'b00),            .de(vid_de), .q(tmds_r));

endmodule
