`timescale 1ns / 1ps

import roce_pkg::*;

// RDMA stack: RoCE v2 (reliable connection, RDMA WRITE and READ) over
// IPv4 / UDP, with ARP and ICMP, between an Ethernet MAC and a payload
// memory. One clock, DATA_BITS wide: 512 bits for 100G (make rdma_100),
// 1024 bits for 200G (make rdma_200), the width the HLS IPs were built at.
//
// This is the top level of the packaged IP; doc/rdma_stack.md describes the
// interfaces. All addresses (IPv4, MAC) have their first octet in the top
// bits. Every *_tdata layout is in units of 32-bit words, word 0 in bits 31:0.
//
//   s_axis_rx / m_axis_tx    Ethernet frames without FCS (to / from the MAC).
//                            TX frames are padded to 60 bytes (TX_PAD).
//                            RX_FCS_FILTER = 1: s_axis_rx_tuser on the last
//                            beat marks a bad FCS and such frames are dropped
//                            (store and forward, s_axis_rx_tready is then 1).
//   local_mac, local_ip      the node's addresses, taken whenever they change
//   s_axis_arp               optional: resolve an IPv4 address ahead of the
//                            first packet to it (the stack resolves on its own)
//   s_axis_qp                connect a QP / update its r_key or send PSN
//   s_axis_sq                RDMA WRITE / READ of any length (a multiple of
//                            4 bytes), split into requests of at most 4 KiB
//   m_axis_cq                one completion per request, flagged on the last
//                            request of a message; never stalls (no tready)
//   m_axis_rd_req / s_axis_rd    payload source: the stack asks for the
//                            bytes it sends (WRITEs, READ responses) and takes
//                            them in request order, a packet per request
//   m_axis_wr_req / m_axis_wr    payload sink: incoming WRITE and READ
//                            response payload, a packet per request
//   stat_*                   counters, free running from reset
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

    input  wire [47:0]             local_mac,
    input  wire [31:0]             local_ip,

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

    // ARP lookup: IPv4 address
    input  wire                    s_axis_arp_tvalid,
    output wire                    s_axis_arp_tready,
    input  wire [31:0]             s_axis_arp_tdata,

    // QP setup, 8 words:
    //   0  [15:0] local QPN, [17:16] update: 0 = connect (all fields),
    //      1 = r_key only, 2 = remote PSN only
    //   1  [23:0] remote QPN
    //   2  [23:0] local PSN: the first PSN expected from the peer
    //   3  [23:0] remote PSN: the first PSN sent to the peer
    //   4  remote IPv4 address
    //   5  [15:0] remote UDP port (0 = 4791)
    //   6  r_key
    //   7  reserved
    input  wire                    s_axis_qp_tvalid,
    output wire                    s_axis_qp_tready,
    input  wire [255:0]            s_axis_qp_tdata,

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
    output wire                    m_axis_wr_tlast,

    // statistics
    output wire [31:0]             stat_rx_frames,      // into the stack
    output wire [31:0]             stat_tx_frames,
    output wire [31:0]             stat_arp_rx,
    output wire [31:0]             stat_arp_tx,
    output wire [31:0]             stat_icmp_rx,
    output wire [31:0]             stat_icmp_tx,
    output wire [31:0]             stat_roce_rx,        // RoCE packets into the transport
    output wire [31:0]             stat_roce_tx,
    output wire [31:0]             stat_psn_drops,      // out-of-sequence packets dropped
    output wire [31:0]             stat_retrans,        // retransmissions
    output wire [31:0]             stat_icrc_drops,
    output wire [31:0]             stat_ack_held,       // cycles an ACK was held (ACK_GAP_CYCLES)
    output wire [31:0]             stat_tx_trimmed,
    output wire [31:0]             stat_stray_cq,       // transport completions with nothing outstanding
    output wire [31:0]             stat_fcs_drops,      // RX_FCS_FILTER: bad FCS
    output wire [31:0]             stat_rx_overflows,   // RX_FCS_FILTER: no room
    output wire                    stat_tx_stalled      // TX blocked for 2^16 cycles
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

    assign s_axis_qp_tready = !qp_busy;

    always_ff @(posedge aclk) begin
        if (!resetn) begin
            qp_valid <= 1'b0;
            conn_valid <= 1'b0;
        end else begin
            if (qp_ready)
                qp_valid <= 1'b0;
            if (conn_ready)
                conn_valid <= 1'b0;
            if (s_axis_qp_tvalid && s_axis_qp_tready) begin
                qp_valid <= 1'b1;
                conn_valid <= s_axis_qp_tdata[17:16] != 2'd1 && s_axis_qp_tdata[17:16] != 2'd2;
            end
        end
    end
    assign qp_busy = qp_valid || conn_valid;

    always_ff @(posedge aclk) begin
        if (s_axis_qp_tvalid && s_axis_qp_tready) begin
            qp_data <= '0;
            qp_data.qp_num <= 24'(s_axis_qp_tdata[15:0]);
            qp_data.new_state <= 32'd2;                         // READY_RECV
            qp_data.local_psn <= s_axis_qp_tdata[64 +: 24];
            qp_data.remote_psn <= s_axis_qp_tdata[96 +: 24];
            qp_data.r_key <= s_axis_qp_tdata[192 +: 32];
            qp_data.vaddr <= s_axis_qp_tdata[17:16] == 2'd1 ? VADDR_RKEY_ONLY :
                             s_axis_qp_tdata[17:16] == 2'd2 ? VADDR_RPSN_ONLY : 48'd0;
            conn_data <= '0;
            conn_data.local_qpn <= s_axis_qp_tdata[15:0];
            conn_data.remote_qpn <= s_axis_qp_tdata[32 +: 24];
            conn_data.remote_ip_address <= {4{bswap32(s_axis_qp_tdata[128 +: 32])}};
            conn_data.remote_udp_port <= s_axis_qp_tdata[160 +: 16] == 0 ? 16'd4791 : s_axis_qp_tdata[160 +: 16];
        end
    end

    // ------------------------------------------------------------ send queue
    // a message is split into requests of at most one PMTU
    logic        msg_active;
    logic        msg_read;
    logic [5:0]  msg_qpn;
    logic [47:0] msg_laddr, msg_raddr;
    logic [31:0] msg_left;
    logic        sq_valid, sq_ready;
    sq_req_t     sq_data;

    wire [31:0] piece = msg_left > PMTU ? PMTU : msg_left;
    wire        piece_last = msg_left <= PMTU;

    assign s_axis_sq_tready = !msg_active;
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
        end else if (s_axis_sq_tvalid && s_axis_sq_tready) begin
            msg_active <= s_axis_sq_tdata[63:32] != 0;
            msg_read <= s_axis_sq_tdata[0];
            msg_qpn <= s_axis_sq_tdata[13:8];
            msg_left <= s_axis_sq_tdata[63:32];
            msg_laddr <= s_axis_sq_tdata[64 +: 48];
            msg_raddr <= s_axis_sq_tdata[128 +: 48];
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
        .s_arp_valid(s_axis_arp_tvalid), .s_arp_ready(s_axis_arp_tready), .s_arp_data(bswap32(s_axis_arp_tdata)),
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
    assign stat_rx_frames = stats.rx_pkg_counter;
    assign stat_tx_frames = stats.tx_pkg_counter;
    assign stat_arp_rx = stats.arp_rx_pkg_counter;
    assign stat_arp_tx = stats.arp_tx_pkg_counter;
    assign stat_icmp_rx = stats.icmp_rx_pkg_counter;
    assign stat_icmp_tx = stats.icmp_tx_pkg_counter;
    assign stat_roce_rx = stats.roce_rx_pkg_counter;
    assign stat_roce_tx = stats.roce_tx_pkg_counter;
    assign stat_psn_drops = stats.roce_psn_drop_counter;
    assign stat_retrans = stats.roce_retrans_counter;
    assign stat_icrc_drops = stats2[0];
    assign stat_ack_held = stats2[1];
    assign stat_tx_trimmed = stats2[2];
    assign stat_stray_cq = stats2[3];
    assign stat_fcs_drops = fcs_drops;
    assign stat_rx_overflows = rx_overflows;
    assign stat_tx_stalled = stats.axis_stream_down;
endmodule
