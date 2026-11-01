`timescale 1ns / 1ps

import roce_pkg::*;

// RDMA stack: RoCE v2 (reliable connection, RDMA WRITE and READ) over
// IPv4 / UDP, with ARP and ICMP, between an Ethernet MAC and a payload
// memory. One clock, DATA_BITS wide: 512 bits for 100G (make rdma_100),
// 1024 bits for 200G (make rdma_200), the width the HLS IPs were built at.
//
// This is the top level of the packaged IP; doc/rdma_stack.md describes the
// interfaces and the register map. All addresses (IPv4, MAC) have their first
// octet in the top bits. Every *_tdata layout is in units of 32-bit words,
// word 0 in bits 31:0.
//
//   s_axil                   registers (rdma_ctrl, 4 KiB): MAC and IPv4
//                            address, ARP lookup, QP setup, a send queue,
//                            completion counters, statistics
//   s_axis_rx / m_axis_tx    Ethernet frames without FCS (to / from the MAC).
//                            TX frames are padded to 60 bytes (TX_PAD).
//                            RX_FCS_FILTER = 1: s_axis_rx_tuser on the last
//                            beat marks a bad FCS and such frames are dropped
//                            (store and forward, s_axis_rx_tready is then 1).
//   s_axis_sq                RDMA WRITE / READ of any length (a multiple of
//                            4 bytes), split into requests of at most 4 KiB;
//                            shared with the register send queue, message by
//                            message
//   m_axis_cq                one completion per request, flagged on the last
//                            request of a message; never stalls (no tready)
//   m_axis_rd_req / s_axis_rd    payload source: the stack asks for the
//                            bytes it sends (WRITEs, READ responses) and takes
//                            them in request order, a packet per request
//   m_axis_wr_req / m_axis_wr    payload sink: incoming WRITE and READ
//                            response payload, a packet per request
module rdma_stack #(
    parameter integer DATA_BITS = 1024,
    parameter integer RT_QP_BITS = 3,           // QPs 0 .. 2^RT_QP_BITS-1 can retransmit WRITEs
                                                // (on-chip buffer: 2^RT_QP_BITS * 128 KiB)
    parameter integer WR_WINDOW = 32,           // outstanding WRITE requests per QP, <= 32
    parameter integer RD_WINDOW = 32,           // outstanding READ requests per QP, <= 32
    parameter integer ACK_GAP_CYCLES = 20,      // minimum cycles between received ACKs
    parameter integer TX_PAD = 1,               // pad TX frames to 60 bytes (the MAC does not)
    parameter integer RX_FCS_FILTER = 0,        // drop RX frames with s_axis_rx_tuser set
    parameter integer RX_FCS_FILTER_ADDR_BITS = 9   // its buffer: 2^N beats
) (
    input  wire                    aclk,
    input  wire                    aresetn,

    // registers
    input  wire [11:0]             s_axil_awaddr,
    input  wire [2:0]              s_axil_awprot,
    input  wire                    s_axil_awvalid,
    output wire                    s_axil_awready,
    input  wire [31:0]             s_axil_wdata,
    input  wire [3:0]              s_axil_wstrb,
    input  wire                    s_axil_wvalid,
    output wire                    s_axil_wready,
    output wire [1:0]              s_axil_bresp,
    output wire                    s_axil_bvalid,
    input  wire                    s_axil_bready,
    input  wire [11:0]             s_axil_araddr,
    input  wire [2:0]              s_axil_arprot,
    input  wire                    s_axil_arvalid,
    output wire                    s_axil_arready,
    output wire [31:0]             s_axil_rdata,
    output wire [1:0]              s_axil_rresp,
    output wire                    s_axil_rvalid,
    input  wire                    s_axil_rready,

    // network
    input  wire                    s_axis_rx_tvalid,
    output wire                    s_axis_rx_tready,
    input  wire [DATA_BITS-1:0]    s_axis_rx_tdata,
    input  wire [DATA_BITS/8-1:0]  s_axis_rx_tkeep,
    input  wire                    s_axis_rx_tlast,
    input  wire                    s_axis_rx_tuser,

    output wire                    m_axis_tx_tvalid,
    input  wire                    m_axis_tx_tready,
    output wire [DATA_BITS-1:0]    m_axis_tx_tdata,
    output wire [DATA_BITS/8-1:0]  m_axis_tx_tkeep,
    output wire                    m_axis_tx_tlast,

    // send queue, 6 words:
    //   0  [0] 0 = RDMA WRITE, 1 = RDMA READ; [13:8] QPN
    //   1  length in bytes, a multiple of 4, > 0
    //   2, 3  local address (bits 47:0): WRITE source / READ destination
    //   4, 5  remote virtual address (bits 47:0)
    input  wire                    s_axis_sq_tvalid,
    output wire                    s_axis_sq_tready,
    input  wire [191:0]            s_axis_sq_tdata,

    // completions: [0] 1 = READ, 0 = WRITE; [1] last request of its message;
    // [13:8] QPN. Per QP, WRITEs and READs each complete in posting order.
    output wire                    m_axis_cq_tvalid,
    output wire [31:0]             m_axis_cq_tdata,

    // payload requests, 4 words:
    //   0, 1  address (bits 47:0): the local address of a WRITE (rd), the
    //         remote virtual address of a READ request served (rd), the
    //         target of an incoming WRITE (wr) or of a READ response (wr: the
    //         local address of the READ)
    //   2  length in bytes
    //   3  [4:0] InfiniBand opcode, [13:8] QPN, [16] last packet of the message
    // Requests for WRITEs on QPs >= 2^RT_QP_BITS repeat when the transport
    // retransmits: the source must keep that data until the WRITE completes.
    output wire                    m_axis_rd_req_tvalid,
    input  wire                    m_axis_rd_req_tready,
    output wire [127:0]            m_axis_rd_req_tdata,
    input  wire                    s_axis_rd_tvalid,
    output wire                    s_axis_rd_tready,
    input  wire [DATA_BITS-1:0]    s_axis_rd_tdata,
    input  wire [DATA_BITS/8-1:0]  s_axis_rd_tkeep,
    input  wire                    s_axis_rd_tlast,

    output wire                    m_axis_wr_req_tvalid,
    input  wire                    m_axis_wr_req_tready,
    output wire [127:0]            m_axis_wr_req_tdata,
    output wire                    m_axis_wr_tvalid,
    input  wire                    m_axis_wr_tready,
    output wire [DATA_BITS-1:0]    m_axis_wr_tdata,
    output wire [DATA_BITS/8-1:0]  m_axis_wr_tkeep,
    output wire                    m_axis_wr_tlast
);
    localparam integer BYTES = DATA_BITS / 8;
    localparam integer QP_BITS = 6;

    initial begin
        if (DATA_BITS != 512 && DATA_BITS != 1024)
            $error("rdma_stack: DATA_BITS must be 512 or 1024");
        if (WR_WINDOW > 32 || RD_WINDOW > 32)
            $error("rdma_stack: WR_WINDOW and RD_WINDOW must be <= 32");
    end

    logic resetn = 1'b0;
    always_ff @(posedge aclk)
        resetn <= aresetn;

    // ------------------------------------------------------------ registers
    localparam integer NSTATS = 16;

    logic [47:0]          local_mac;
    logic [31:0]          local_ip;
    logic                 arp_valid, arp_ready;
    logic [31:0]          arp_data;
    logic                 qpw_valid, qpw_ready;
    logic [255:0]         qpw_data;
    logic                 rsq_valid, rsq_ready;
    logic [191:0]         rsq_data;
    logic [NSTATS*32-1:0] stat_words;
    logic                 tx_stalled;
    logic                 sq_valid, sq_ready;
    sq_req_t              sq_data;

    rdma_ctrl #(
        .DATA_BITS(DATA_BITS), .RT_QP_BITS(RT_QP_BITS), .WR_WINDOW(WR_WINDOW), .RD_WINDOW(RD_WINDOW),
        .NSTATS(NSTATS)
    ) inst_ctrl (
        .clk(aclk), .resetn(resetn),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .local_mac(local_mac), .local_ip(local_ip),
        .m_arp_valid(arp_valid), .m_arp_ready(arp_ready), .m_arp_data(arp_data),
        .m_qp_valid(qpw_valid), .m_qp_ready(qpw_ready), .m_qp_data(qpw_data),
        .m_sq_valid(rsq_valid), .m_sq_ready(rsq_ready), .m_sq_data(rsq_data),
        .sq_req(sq_valid && sq_ready), .cq_valid(m_axis_cq_tvalid), .cq_data(m_axis_cq_tdata),
        .stats(stat_words), .tx_stalled(tx_stalled)
    );

    // ------------------------------------------------------------ addresses
    // handed to the stack on every change and for a few cycles after reset
    // (its own reset is a cycle later)
    logic [47:0] mac_r;
    logic [31:0] ip_r;
    logic        mac_set, ip_set;
    logic [3:0]  init;
    always_ff @(posedge aclk) begin
        mac_r <= local_mac;
        ip_r <= local_ip;
        if (!resetn) begin
            init <= '1;
            mac_set <= 1'b0;
            ip_set <= 1'b0;
        end else begin
            if (init != 0)
                init <= init - 1'b1;
            mac_set <= mac_r != local_mac || init != 0;
            ip_set <= ip_r != local_ip || init != 0;
        end
    end

    // ------------------------------------------------------------ RX
    logic                 rx_tvalid, rx_tready, rx_tlast;
    logic [DATA_BITS-1:0] rx_tdata;
    logic [BYTES-1:0]     rx_tkeep;
    logic [31:0]          fcs_drops, rx_overflows;

    if (RX_FCS_FILTER) begin : g_fcs
        rx_fcs_filter #(.DATA_BITS(DATA_BITS), .ADDR_BITS(RX_FCS_FILTER_ADDR_BITS)) inst_fcs (
            .aclk(aclk), .aresetn(resetn),
            .s_tvalid(s_axis_rx_tvalid), .s_tdata(s_axis_rx_tdata), .s_tkeep(s_axis_rx_tkeep),
            .s_tlast(s_axis_rx_tlast), .s_tuser(s_axis_rx_tuser),
            .m_tvalid(rx_tvalid), .m_tready(rx_tready), .m_tdata(rx_tdata), .m_tkeep(rx_tkeep),
            .m_tlast(rx_tlast),
            .bad_fcs_frames(fcs_drops), .overflow_frames(rx_overflows)
        );
        assign s_axis_rx_tready = 1'b1;
    end else begin : g_no_fcs
        assign rx_tvalid = s_axis_rx_tvalid;
        assign s_axis_rx_tready = rx_tready;
        assign rx_tdata = s_axis_rx_tdata;
        assign rx_tkeep = s_axis_rx_tkeep;
        assign rx_tlast = s_axis_rx_tlast;
        assign fcs_drops = '0;
        assign rx_overflows = '0;
    end

    // ------------------------------------------------------------ QP setup
    localparam logic [47:0] VADDR_RKEY_ONLY = 48'hDEAD_BEEF;   // rocev2 qp_interface: r_key only
    localparam logic [47:0] VADDR_RPSN_ONLY = 48'hFEED_BEEF;   // remote PSN only

    logic         qp_busy, qp_valid, qp_ready, conn_valid, conn_ready;
    qp_ctx_hls_t  qp_data;
    qp_conn_hls_t conn_data;

    assign qpw_ready = !qp_busy;

    always_ff @(posedge aclk) begin
        if (!resetn) begin
            qp_valid <= 1'b0;
            conn_valid <= 1'b0;
        end else begin
            if (qp_ready)
                qp_valid <= 1'b0;
            if (conn_ready)
                conn_valid <= 1'b0;
            if (qpw_valid && qpw_ready) begin
                qp_valid <= 1'b1;
                conn_valid <= qpw_data[17:16] != 2'd1 && qpw_data[17:16] != 2'd2;
            end
        end
    end
    assign qp_busy = qp_valid || conn_valid;

    always_ff @(posedge aclk) begin
        if (qpw_valid && qpw_ready) begin
            qp_data <= '0;
            qp_data.qp_num <= 24'(qpw_data[15:0]);
            qp_data.new_state <= 32'd2;                         // READY_RECV
            qp_data.local_psn <= qpw_data[64 +: 24];
            qp_data.remote_psn <= qpw_data[96 +: 24];
            qp_data.r_key <= qpw_data[192 +: 32];
            qp_data.vaddr <= qpw_data[17:16] == 2'd1 ? VADDR_RKEY_ONLY :
                             qpw_data[17:16] == 2'd2 ? VADDR_RPSN_ONLY : 48'd0;
            conn_data <= '0;
            conn_data.local_qpn <= qpw_data[15:0];
            conn_data.remote_qpn <= qpw_data[32 +: 24];
            conn_data.remote_ip_address <= {4{bswap32(qpw_data[128 +: 32])}};
            conn_data.remote_udp_port <= qpw_data[160 +: 16] == 0 ? 16'd4791 : qpw_data[160 +: 16];
        end
    end

    // ------------------------------------------------------------ send queue
    // Messages from s_axis_sq and from the register send queue, taken in turn
    // when both wait; a message is split into requests of at most one PMTU.
    logic        msg_active;
    logic        msg_read;
    logic [5:0]  msg_qpn;
    logic [47:0] msg_laddr, msg_raddr;
    logic [31:0] msg_left;
    logic        last_reg;                  // the last message came from the registers

    wire [31:0] piece = msg_left > PMTU ? PMTU : msg_left;
    wire        piece_last = msg_left <= PMTU;

    wire          take_reg = rsq_valid && (!s_axis_sq_tvalid || !last_reg);
    wire          sq_in_valid = s_axis_sq_tvalid || rsq_valid;
    wire          sq_in_ready = !msg_active;
    wire [191:0]  sq_in_data = take_reg ? rsq_data : s_axis_sq_tdata;

    assign s_axis_sq_tready = sq_in_ready && !take_reg;
    assign rsq_ready = sq_in_ready && take_reg;
    assign sq_valid = msg_active;

    always_comb begin
        sq_data = '0;
        sq_data.op = msg_read ? RC_RDMA_READ_REQUEST : RC_RDMA_WRITE_ONLY;
        sq_data.qpn = msg_qpn;
        sq_data.laddr = msg_laddr;
        sq_data.raddr = msg_raddr;
        sq_data.len = 28'(piece);
    end

    always_ff @(posedge aclk) begin
        if (!resetn) begin
            msg_active <= 1'b0;
            last_reg <= 1'b0;
        end else if (sq_in_valid && sq_in_ready) begin
            last_reg <= take_reg;
            msg_active <= sq_in_data[63:32] != 0;
            msg_read <= sq_in_data[0];
            msg_qpn <= sq_in_data[13:8];
            msg_left <= sq_in_data[63:32];
            msg_laddr <= sq_in_data[64 +: 48];
            msg_raddr <= sq_in_data[128 +: 48];
        end else if (sq_valid && sq_ready) begin
            msg_active <= !piece_last;
            msg_left <= msg_left - piece;
            msg_laddr <= msg_laddr + piece;
            msg_raddr <= msg_raddr + piece;
        end
    end

    // ------------------------------------------------------------ completions
    // Per QP, the transport completes WRITEs and READs each in posting order:
    // a FIFO of "last request of the message" flags per QP and kind, 64 deep
    // (a window of up to 32 plus the request roce_flow holds).
    logic       ack_valid;
    ack_t       ack_data;
    logic       last_flags [2][2**QP_BITS * 64];
    logic [5:0] lf_head [2][2**QP_BITS];
    logic [5:0] lf_tail [2][2**QP_BITS];

    wire        post = sq_valid && sq_ready;
    wire        ack_read = ack_data.opcode != RC_ACK;

    always_ff @(posedge aclk) begin
        if (post)
            last_flags[msg_read][{msg_qpn, lf_tail[msg_read][msg_qpn]}] <= piece_last;
        if (!resetn) begin
            for (int k = 0; k < 2; k++)
                for (int q = 0; q < 2**QP_BITS; q++) begin
                    lf_head[k][q] <= '0;
                    lf_tail[k][q] <= '0;
                end
        end else begin
            if (post)
                lf_tail[msg_read][msg_qpn] <= lf_tail[msg_read][msg_qpn] + 1'b1;
            if (ack_valid)
                lf_head[ack_read][ack_data.qpn] <= lf_head[ack_read][ack_data.qpn] + 1'b1;
        end
    end

    logic        cq_valid;
    logic [31:0] cq_data;
    always_ff @(posedge aclk) begin
        cq_valid <= resetn && ack_valid;
        cq_data <= '0;
        cq_data[0] <= ack_read;
        cq_data[1] <= last_flags[ack_read][{ack_data.qpn, lf_head[ack_read][ack_data.qpn]}];
        cq_data[13:8] <= ack_data.qpn;
    end
    assign m_axis_cq_tvalid = cq_valid;
    assign m_axis_cq_tdata = cq_data;

    // ------------------------------------------------------------ payload requests
    logic     rd_req_valid, wr_req_valid;
    mem_req_t rd_req, wr_req;

    function automatic logic [127:0] req_word(input mem_req_t r);
        req_word = '0;
        req_word[47:0] = r.vaddr;
        req_word[64 +: 28] = r.len;
        req_word[96 +: 5] = r.opcode;
        req_word[104 +: 6] = r.qpn;
        req_word[112] = r.last;
    endfunction

    assign m_axis_rd_req_tvalid = rd_req_valid;
    assign m_axis_rd_req_tdata = req_word(rd_req);
    assign m_axis_wr_req_tvalid = wr_req_valid;
    assign m_axis_wr_req_tdata = req_word(wr_req);

    // ------------------------------------------------------------ stack
    logic                 tx_tvalid, tx_tready, tx_tlast;
    logic [DATA_BITS-1:0] tx_tdata;
    logic [BYTES-1:0]     tx_tkeep;
    net_stat_t            stats;
    logic [7:0][31:0]     stats2;

    eth_roce_stack #(
        .DATA_BITS(DATA_BITS), .RT_QP_BITS(RT_QP_BITS), .WR_WINDOW(WR_WINDOW), .RD_WINDOW(RD_WINDOW),
        .ACK_GAP_CYCLES(ACK_GAP_CYCLES)
    ) inst_stack (
        .clk(aclk), .resetn(resetn),
        .s_net_tvalid(rx_tvalid), .s_net_tready(rx_tready), .s_net_tdata(rx_tdata),
        .s_net_tkeep(rx_tkeep), .s_net_tlast(rx_tlast),
        .m_net_tvalid(tx_tvalid), .m_net_tready(tx_tready), .m_net_tdata(tx_tdata),
        .m_net_tkeep(tx_tkeep), .m_net_tlast(tx_tlast),
        .s_mac_valid(mac_set), .s_mac_ready(), .s_mac_data(mac_r),
        .s_ip_valid(ip_set), .s_ip_ready(), .s_ip_data(ip_r),
        .s_arp_valid(arp_valid), .s_arp_ready(arp_ready), .s_arp_data(bswap32(arp_data)),
        .s_qp_valid(qp_valid), .s_qp_ready(qp_ready), .s_qp_data(qp_data),
        .s_conn_valid(conn_valid), .s_conn_ready(conn_ready), .s_conn_data(conn_data),
        .s_sq_valid(sq_valid), .s_sq_ready(sq_ready), .s_sq_data(sq_data),
        .m_ack_valid(ack_valid), .m_ack_data(ack_data),
        .m_rd_req_valid(rd_req_valid), .m_rd_req_ready(m_axis_rd_req_tready), .m_rd_req_data(rd_req),
        .s_rd_tvalid(s_axis_rd_tvalid), .s_rd_tready(s_axis_rd_tready), .s_rd_tdata(s_axis_rd_tdata),
        .s_rd_tkeep(s_axis_rd_tkeep), .s_rd_tlast(s_axis_rd_tlast),
        .m_wr_req_valid(wr_req_valid), .m_wr_req_ready(m_axis_wr_req_tready), .m_wr_req_data(wr_req),
        .m_wr_tvalid(m_axis_wr_tvalid), .m_wr_tready(m_axis_wr_tready), .m_wr_tdata(m_axis_wr_tdata),
        .m_wr_tkeep(m_axis_wr_tkeep), .m_wr_tlast(m_axis_wr_tlast),
        .m_stats(stats), .m_stats2(stats2)
    );

    // ------------------------------------------------------------ TX padding
    // a frame shorter than 60 bytes is a single beat
    localparam integer MIN_BYTES = 60;

    if (TX_PAD) begin : g_pad
        logic                 p_tvalid, p_tlast, first;
        logic [DATA_BITS-1:0] p_tdata;
        logic [BYTES-1:0]     p_tkeep;

        assign tx_tready = !p_tvalid || m_axis_tx_tready;

        always_ff @(posedge aclk) begin
            if (!resetn) begin
                p_tvalid <= 1'b0;
                first <= 1'b1;
            end else begin
                if (tx_tready) begin
                    p_tvalid <= tx_tvalid;
                    p_tdata <= tx_tdata;
                    p_tkeep <= tx_tkeep;
                    p_tlast <= tx_tlast;
                    if (tx_tvalid && tx_tlast && first)
                        for (int i = 0; i < MIN_BYTES; i++)
                            if (!tx_tkeep[i]) begin
                                p_tkeep[i] <= 1'b1;
                                p_tdata[i*8 +: 8] <= 8'h00;
                            end
                end
                if (tx_tvalid && tx_tready)
                    first <= tx_tlast;
            end
        end

        assign m_axis_tx_tvalid = p_tvalid;
        assign m_axis_tx_tdata = p_tdata;
        assign m_axis_tx_tkeep = p_tkeep;
        assign m_axis_tx_tlast = p_tlast;
    end else begin : g_no_pad
        assign m_axis_tx_tvalid = tx_tvalid;
        assign tx_tready = m_axis_tx_tready;
        assign m_axis_tx_tdata = tx_tdata;
        assign m_axis_tx_tkeep = tx_tkeep;
        assign m_axis_tx_tlast = tx_tlast;
    end

    // ------------------------------------------------------------ statistics
    // registers 0x200 + 4 i, in this order (doc/rdma_stack.md)
    assign stat_words = {
        rx_overflows, fcs_drops, stats2[3], stats2[2], stats2[1], stats2[0],
        stats.roce_retrans_counter, stats.roce_psn_drop_counter,
        stats.roce_tx_pkg_counter, stats.roce_rx_pkg_counter,
        stats.icmp_tx_pkg_counter, stats.icmp_rx_pkg_counter,
        stats.arp_tx_pkg_counter, stats.arp_rx_pkg_counter,
        stats.tx_pkg_counter, stats.rx_pkg_counter
    };
    assign tx_stalled = stats.axis_stream_down;
endmodule
