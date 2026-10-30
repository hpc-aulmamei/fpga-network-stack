`timescale 1ns / 1ps

import roce_pkg::*;

// Ethernet / IPv4 / ARP / ICMP / RoCE v2 stack, DATA_BITS wide (512 or 1024,
// the width the HLS IPs were built at), one clock. Built from the HLS IPs of
// this repository:
//
//   RX: frames -> ip_handler_ip -+-> ARP  -> arp_server_subnet_ip
//                                +-> ICMP -> DATA_BITS/64 -> icmp_server_ip
//                                +-> RoCE -> roce_engine
//                                +-> anything else: dropped
//   TX: roce_engine --+--> IP merge -> mac_ip_encode_ip --+--> frame merge -> frames
//       icmp_server --+    (ARP lookup                    |
//       (64/DATA_BITS)     via arp_server_subnet_ip)      |
//       arp_server_subnet_ip -----------------------------+
//
// Addresses are configured in normal order (first octet in the top bits) and
// handed to the IPs in network byte order. ARP_LOOKUP requests from the host
// (already in network byte order) fill the ARP table; their replies are
// dropped. Subnet 255.255.255.0, gateway = own address.
module eth_roce_stack #(
    parameter integer DATA_BITS = 1024,
    parameter integer RT_QP_BITS = 3,
    parameter integer WR_WINDOW = 32,
    parameter integer RD_WINDOW = 32,
    parameter integer ACK_GAP_CYCLES = 20
) (
    input  logic          clk,
    input  logic          resetn,

    // Ethernet frames (no FCS)
    input  logic          s_net_tvalid,
    output logic          s_net_tready,
    input  logic [DATA_BITS-1:0] s_net_tdata,
    input  logic [DATA_BITS/8-1:0] s_net_tkeep,
    input  logic          s_net_tlast,

    output logic          m_net_tvalid,
    input  logic          m_net_tready,
    output logic [DATA_BITS-1:0] m_net_tdata,
    output logic [DATA_BITS/8-1:0] m_net_tkeep,
    output logic          m_net_tlast,

    // configuration
    input  logic          s_mac_valid,
    output logic          s_mac_ready,
    input  logic [47:0]   s_mac_data,
    input  logic          s_ip_valid,
    output logic          s_ip_ready,
    input  logic [31:0]   s_ip_data,
    input  logic          s_arp_valid,
    output logic          s_arp_ready,
    input  logic [31:0]   s_arp_data,

    // RoCE
    input  logic          s_qp_valid,
    output logic          s_qp_ready,
    input  qp_ctx_hls_t   s_qp_data,
    input  logic          s_conn_valid,
    output logic          s_conn_ready,
    input  qp_conn_hls_t  s_conn_data,
    input  logic          s_sq_valid,
    output logic          s_sq_ready,
    input  sq_req_t       s_sq_data,
    output logic          m_ack_valid,
    output ack_t          m_ack_data,

    output logic          m_rd_req_valid,
    input  logic          m_rd_req_ready,
    output mem_req_t      m_rd_req_data,
    input  logic          s_rd_tvalid,
    output logic          s_rd_tready,
    input  logic [DATA_BITS-1:0] s_rd_tdata,
    input  logic [DATA_BITS/8-1:0] s_rd_tkeep,
    input  logic          s_rd_tlast,

    output logic          m_wr_req_valid,
    input  logic          m_wr_req_ready,
    output mem_req_t      m_wr_req_data,
    output logic          m_wr_tvalid,
    input  logic          m_wr_tready,
    output logic [DATA_BITS-1:0] m_wr_tdata,
    output logic [DATA_BITS/8-1:0] m_wr_tkeep,
    output logic          m_wr_tlast,

    output net_stat_t     m_stats,
    output logic [7:0][31:0] m_stats2           // engine details: ICRC drops, ACK hold cycles, trimmed, stray completions
);
    // ------------------------------------------------------------ resets
    (* max_fanout = 64 *) logic rst_n_ip, rst_n_arp, rst_n_icmp, rst_n_mie, rst_n_io, rst_n_eng;
    always_ff @(posedge clk) begin
        rst_n_ip <= resetn;
        rst_n_arp <= resetn;
        rst_n_icmp <= resetn;
        rst_n_mie <= resetn;
        rst_n_io <= resetn;
        rst_n_eng <= resetn;
    end

    // ------------------------------------------------------------ configuration
    logic [47:0] my_mac;                        // network byte order
    logic [31:0] my_ip;                         // network byte order
    logic [31:0] my_ip_n;                       // normal order
    assign s_mac_ready = 1'b1;
    assign s_ip_ready = 1'b1;
    always_ff @(posedge clk) begin
        if (!rst_n_io) begin
            my_mac <= '0;
            my_ip <= '0;
            my_ip_n <= '0;
        end else begin
            if (s_mac_valid)
                my_mac <= bswap48(s_mac_data);
            if (s_ip_valid) begin
                my_ip <= bswap32(s_ip_data);
                my_ip_n <= s_ip_data;
            end
        end
    end
    localparam logic [31:0] SUBNET_MASK = 32'h00ffffff;     // 255.255.255.0, network order

    // ------------------------------------------------------------ RX
    logic          n_tvalid, n_tready, n_tlast;
    logic [DATA_BITS-1:0] n_tdata;
    logic [DATA_BITS/8-1:0] n_tkeep;

    axis_skid #(.DATA_BITS(DATA_BITS + DATA_BITS / 8 + 1)) inst_rx_slice (
        .clk(clk), .resetn(rst_n_io),
        .s_valid(s_net_tvalid), .s_ready(s_net_tready), .s_data({s_net_tlast, s_net_tkeep, s_net_tdata}),
        .m_valid(n_tvalid), .m_ready(n_tready), .m_data({n_tlast, n_tkeep, n_tdata})
    );

    logic          arp_rx_tvalid, arp_rx_tready, arp_rx_tlast;
    logic [DATA_BITS-1:0] arp_rx_tdata;
    logic [DATA_BITS/8-1:0] arp_rx_tkeep;
    logic          icmp_rx_tvalid, icmp_rx_tready, icmp_rx_tlast;
    logic [DATA_BITS-1:0] icmp_rx_tdata;
    logic [DATA_BITS/8-1:0] icmp_rx_tkeep;
    logic          roce_rx_tvalid, roce_rx_tready, roce_rx_tlast;
    logic [DATA_BITS-1:0] roce_rx_tdata;
    logic [DATA_BITS/8-1:0] roce_rx_tkeep;

    ip_handler_ip inst_ip_handler (
        .ap_clk(clk), .ap_rst_n(rst_n_ip),
        .s_axis_raw_TVALID(n_tvalid), .s_axis_raw_TREADY(n_tready),
        .s_axis_raw_TDATA(n_tdata), .s_axis_raw_TKEEP(n_tkeep), .s_axis_raw_TSTRB(n_tkeep), .s_axis_raw_TLAST(n_tlast),
        .m_axis_arp_TVALID(arp_rx_tvalid), .m_axis_arp_TREADY(arp_rx_tready),
        .m_axis_arp_TDATA(arp_rx_tdata), .m_axis_arp_TKEEP(arp_rx_tkeep), .m_axis_arp_TSTRB(), .m_axis_arp_TLAST(arp_rx_tlast),
        .m_axis_icmpv6_TVALID(), .m_axis_icmpv6_TREADY(1'b1),
        .m_axis_icmpv6_TDATA(), .m_axis_icmpv6_TKEEP(), .m_axis_icmpv6_TSTRB(), .m_axis_icmpv6_TLAST(),
        .m_axis_ipv6udp_TVALID(), .m_axis_ipv6udp_TREADY(1'b1),
        .m_axis_ipv6udp_TDATA(), .m_axis_ipv6udp_TKEEP(), .m_axis_ipv6udp_TSTRB(), .m_axis_ipv6udp_TLAST(),
        .m_axis_icmp_TVALID(icmp_rx_tvalid), .m_axis_icmp_TREADY(icmp_rx_tready),
        .m_axis_icmp_TDATA(icmp_rx_tdata), .m_axis_icmp_TKEEP(icmp_rx_tkeep), .m_axis_icmp_TSTRB(), .m_axis_icmp_TLAST(icmp_rx_tlast),
        .m_axis_udp_TVALID(), .m_axis_udp_TREADY(1'b1),
        .m_axis_udp_TDATA(), .m_axis_udp_TKEEP(), .m_axis_udp_TSTRB(), .m_axis_udp_TLAST(),
        .m_axis_tcp_TVALID(), .m_axis_tcp_TREADY(1'b1),
        .m_axis_tcp_TDATA(), .m_axis_tcp_TKEEP(), .m_axis_tcp_TSTRB(), .m_axis_tcp_TLAST(),
        .m_axis_roce_TVALID(roce_rx_tvalid), .m_axis_roce_TREADY(roce_rx_tready),
        .m_axis_roce_TDATA(roce_rx_tdata), .m_axis_roce_TKEEP(roce_rx_tkeep), .m_axis_roce_TSTRB(), .m_axis_roce_TLAST(roce_rx_tlast),
        .myIpAddress(my_ip)
    );

    // ------------------------------------------------------------ ARP
    logic          arp_tx_tvalid, arp_tx_tready, arp_tx_tlast;
    logic [DATA_BITS-1:0] arp_tx_tdata;
    logic [DATA_BITS/8-1:0] arp_tx_tkeep;
    logic          lup_req_valid, lup_req_ready, lup_rsp_valid, lup_rsp_ready;
    logic [31:0]   lup_req_data;
    logic [55:0]   lup_rsp_data;

    arp_server_subnet_ip inst_arp (
        .ap_clk(clk), .ap_rst_n(rst_n_arp),
        .s_axis_TVALID(arp_rx_tvalid), .s_axis_TREADY(arp_rx_tready),
        .s_axis_TDATA(arp_rx_tdata), .s_axis_TKEEP(arp_rx_tkeep), .s_axis_TSTRB(arp_rx_tkeep), .s_axis_TLAST(arp_rx_tlast),
        .m_axis_TVALID(arp_tx_tvalid), .m_axis_TREADY(arp_tx_tready),
        .m_axis_TDATA(arp_tx_tdata), .m_axis_TKEEP(arp_tx_tkeep), .m_axis_TSTRB(), .m_axis_TLAST(arp_tx_tlast),
        .s_axis_arp_lookup_request_TVALID(lup_req_valid), .s_axis_arp_lookup_request_TREADY(lup_req_ready),
        .s_axis_arp_lookup_request_TDATA(lup_req_data),
        .m_axis_arp_lookup_reply_TVALID(lup_rsp_valid), .m_axis_arp_lookup_reply_TREADY(lup_rsp_ready),
        .m_axis_arp_lookup_reply_TDATA(lup_rsp_data),
        .s_axis_host_arp_lookup_request_TVALID(s_arp_valid), .s_axis_host_arp_lookup_request_TREADY(s_arp_ready),
        .s_axis_host_arp_lookup_request_TDATA(s_arp_data),
        .m_axis_host_arp_lookup_reply_TVALID(), .m_axis_host_arp_lookup_reply_TREADY(1'b1),
        .m_axis_host_arp_lookup_reply_TDATA(),
        .myMacAddress(my_mac), .myIpAddress(my_ip),
        .regRequestCount(), .regRequestCount_ap_vld(), .regReplyCount(), .regReplyCount_ap_vld()
    );

    // ------------------------------------------------------------ ICMP (64 bits)
    logic        i_rx_tvalid, i_rx_tready, i_rx_tlast, i_tx_tvalid, i_tx_tready, i_tx_tlast;
    logic [63:0] i_rx_tdata, i_tx_tdata;
    logic [7:0]  i_rx_tkeep, i_tx_tkeep;

    axis_narrow #(.WIDE(DATA_BITS), .NARROW(64)) inst_icmp_narrow (
        .clk(clk), .resetn(rst_n_icmp),
        .s_tvalid(icmp_rx_tvalid), .s_tready(icmp_rx_tready), .s_tdata(icmp_rx_tdata), .s_tkeep(icmp_rx_tkeep), .s_tlast(icmp_rx_tlast),
        .m_tvalid(i_rx_tvalid), .m_tready(i_rx_tready), .m_tdata(i_rx_tdata), .m_tkeep(i_rx_tkeep), .m_tlast(i_rx_tlast)
    );

    icmp_server_ip inst_icmp (
        .ap_clk(clk), .ap_rst_n(rst_n_icmp),
        .s_axis_TVALID(i_rx_tvalid), .s_axis_TREADY(i_rx_tready),
        .s_axis_TDATA(i_rx_tdata), .s_axis_TKEEP(i_rx_tkeep), .s_axis_TSTRB(i_rx_tkeep), .s_axis_TLAST(i_rx_tlast),
        .udpIn_TVALID(1'b0), .udpIn_TREADY(), .udpIn_TDATA(64'd0), .udpIn_TKEEP(8'd0), .udpIn_TSTRB(8'd0), .udpIn_TLAST(1'b0),
        .ttlIn_TVALID(1'b0), .ttlIn_TREADY(), .ttlIn_TDATA(64'd0), .ttlIn_TKEEP(8'd0), .ttlIn_TSTRB(8'd0), .ttlIn_TLAST(1'b0),
        .m_axis_TVALID(i_tx_tvalid), .m_axis_TREADY(i_tx_tready),
        .m_axis_TDATA(i_tx_tdata), .m_axis_TKEEP(i_tx_tkeep), .m_axis_TSTRB(), .m_axis_TLAST(i_tx_tlast)
    );

    logic          icmp_tx_tvalid, icmp_tx_tready, icmp_tx_tlast;
    logic [DATA_BITS-1:0] icmp_tx_tdata;
    logic [DATA_BITS/8-1:0] icmp_tx_tkeep;

    axis_widen #(.WIDE(DATA_BITS), .NARROW(64)) inst_icmp_widen (
        .clk(clk), .resetn(rst_n_icmp),
        .s_tvalid(i_tx_tvalid), .s_tready(i_tx_tready), .s_tdata(i_tx_tdata), .s_tkeep(i_tx_tkeep), .s_tlast(i_tx_tlast),
        .m_tvalid(icmp_tx_tvalid), .m_tready(icmp_tx_tready), .m_tdata(icmp_tx_tdata), .m_tkeep(icmp_tx_tkeep), .m_tlast(icmp_tx_tlast)
    );

    // ------------------------------------------------------------ RoCE
    logic          roce_tx_tvalid, roce_tx_tready, roce_tx_tlast;
    logic [DATA_BITS-1:0] roce_tx_tdata;
    logic [DATA_BITS/8-1:0] roce_tx_tkeep;
    logic [31:0]   e_rx, e_tx, e_ibv_rx, e_ibv_tx, e_psn, e_retrans, e_crc, e_held, e_trim, e_stray;

    roce_engine #(
        .DATA_BITS(DATA_BITS), .RT_QP_BITS(RT_QP_BITS), .WR_WINDOW(WR_WINDOW), .RD_WINDOW(RD_WINDOW), .ACK_GAP_CYCLES(ACK_GAP_CYCLES)
    ) inst_engine (
        .clk(clk), .resetn(rst_n_eng),
        .local_ip(my_ip_n),
        .s_rx_tvalid(roce_rx_tvalid), .s_rx_tready(roce_rx_tready), .s_rx_tdata(roce_rx_tdata),
        .s_rx_tkeep(roce_rx_tkeep), .s_rx_tlast(roce_rx_tlast),
        .m_tx_tvalid(roce_tx_tvalid), .m_tx_tready(roce_tx_tready), .m_tx_tdata(roce_tx_tdata),
        .m_tx_tkeep(roce_tx_tkeep), .m_tx_tlast(roce_tx_tlast),
        .s_qp_valid(s_qp_valid), .s_qp_ready(s_qp_ready), .s_qp_data(s_qp_data),
        .s_conn_valid(s_conn_valid), .s_conn_ready(s_conn_ready), .s_conn_data(s_conn_data),
        .s_sq_valid(s_sq_valid), .s_sq_ready(s_sq_ready), .s_sq_data(s_sq_data),
        .m_ack_valid(m_ack_valid), .m_ack_data(m_ack_data),
        .m_rd_req_valid(m_rd_req_valid), .m_rd_req_ready(m_rd_req_ready), .m_rd_req_data(m_rd_req_data),
        .s_rd_tvalid(s_rd_tvalid), .s_rd_tready(s_rd_tready), .s_rd_tdata(s_rd_tdata),
        .s_rd_tkeep(s_rd_tkeep), .s_rd_tlast(s_rd_tlast),
        .m_wr_req_valid(m_wr_req_valid), .m_wr_req_ready(m_wr_req_ready), .m_wr_req_data(m_wr_req_data),
        .m_wr_tvalid(m_wr_tvalid), .m_wr_tready(m_wr_tready), .m_wr_tdata(m_wr_tdata),
        .m_wr_tkeep(m_wr_tkeep), .m_wr_tlast(m_wr_tlast),
        .stat_rx_pkts(e_rx), .stat_tx_pkts(e_tx), .stat_ibv_rx(e_ibv_rx), .stat_ibv_tx(e_ibv_tx),
        .stat_psn_drops(e_psn), .stat_retrans(e_retrans), .stat_crc_drops(e_crc),
        .stat_ack_held(e_held), .stat_trimmed(e_trim), .stat_stray_acks(e_stray)
    );

    // ------------------------------------------------------------ TX: IP merge, MAC
    logic          ip_tvalid, ip_tready, ip_tlast;
    logic [DATA_BITS-1:0] ip_tdata;
    logic [DATA_BITS/8-1:0] ip_tkeep;

    axis_pkt_merge #(.N(2), .DATA_BITS(DATA_BITS)) inst_ip_merge (
        .clk(clk), .resetn(rst_n_mie),
        .s_tvalid({icmp_tx_tvalid, roce_tx_tvalid}), .s_tready({icmp_tx_tready, roce_tx_tready}),
        .s_tdata({icmp_tx_tdata, roce_tx_tdata}), .s_tkeep({icmp_tx_tkeep, roce_tx_tkeep}),
        .s_tlast({icmp_tx_tlast, roce_tx_tlast}),
        .m_tvalid(ip_tvalid), .m_tready(ip_tready), .m_tdata(ip_tdata), .m_tkeep(ip_tkeep), .m_tlast(ip_tlast)
    );

    logic          eth_tvalid, eth_tready, eth_tlast;
    logic [DATA_BITS-1:0] eth_tdata;
    logic [DATA_BITS/8-1:0] eth_tkeep;

    mac_ip_encode_ip inst_mac_ip_encode (
        .ap_clk(clk), .ap_rst_n(rst_n_mie),
        .s_axis_ip_TVALID(ip_tvalid), .s_axis_ip_TREADY(ip_tready),
        .s_axis_ip_TDATA(ip_tdata), .s_axis_ip_TKEEP(ip_tkeep), .s_axis_ip_TSTRB(ip_tkeep), .s_axis_ip_TLAST(ip_tlast),
        .m_axis_ip_TVALID(eth_tvalid), .m_axis_ip_TREADY(eth_tready),
        .m_axis_ip_TDATA(eth_tdata), .m_axis_ip_TKEEP(eth_tkeep), .m_axis_ip_TSTRB(), .m_axis_ip_TLAST(eth_tlast),
        .m_axis_arp_lookup_request_TVALID(lup_req_valid), .m_axis_arp_lookup_request_TREADY(lup_req_ready),
        .m_axis_arp_lookup_request_TDATA(lup_req_data),
        .s_axis_arp_lookup_reply_TVALID(lup_rsp_valid), .s_axis_arp_lookup_reply_TREADY(lup_rsp_ready),
        .s_axis_arp_lookup_reply_TDATA(lup_rsp_data),
        .myMacAddress(my_mac), .regSubNetMask(SUBNET_MASK), .regDefaultGateway(my_ip)
    );

    logic          o_tvalid, o_tready, o_tlast;
    logic [DATA_BITS-1:0] o_tdata;
    logic [DATA_BITS/8-1:0] o_tkeep;

    axis_pkt_merge #(.N(2), .DATA_BITS(DATA_BITS)) inst_eth_merge (
        .clk(clk), .resetn(rst_n_io),
        .s_tvalid({arp_tx_tvalid, eth_tvalid}), .s_tready({arp_tx_tready, eth_tready}),
        .s_tdata({arp_tx_tdata, eth_tdata}), .s_tkeep({arp_tx_tkeep, eth_tkeep}),
        .s_tlast({arp_tx_tlast, eth_tlast}),
        .m_tvalid(o_tvalid), .m_tready(o_tready), .m_tdata(o_tdata), .m_tkeep(o_tkeep), .m_tlast(o_tlast)
    );

    axis_skid #(.DATA_BITS(DATA_BITS + DATA_BITS / 8 + 1)) inst_tx_slice (
        .clk(clk), .resetn(rst_n_io),
        .s_valid(o_tvalid), .s_ready(o_tready), .s_data({o_tlast, o_tkeep, o_tdata}),
        .m_valid(m_net_tvalid), .m_ready(m_net_tready), .m_data({m_net_tlast, m_net_tkeep, m_net_tdata})
    );

    // ------------------------------------------------------------ statistics
    logic [31:0] c_rx, c_tx, c_arp_rx, c_arp_tx, c_icmp_rx, c_icmp_tx;
    logic [16:0] stall;
    always_ff @(posedge clk) begin
        if (!rst_n_io) begin
            c_rx <= 0; c_tx <= 0; c_arp_rx <= 0; c_arp_tx <= 0; c_icmp_rx <= 0; c_icmp_tx <= 0;
            stall <= 0;
        end else begin
            if (n_tvalid && n_tready && n_tlast) c_rx <= c_rx + 1;
            if (m_net_tvalid && m_net_tready && m_net_tlast) c_tx <= c_tx + 1;
            if (arp_rx_tvalid && arp_rx_tready && arp_rx_tlast) c_arp_rx <= c_arp_rx + 1;
            if (arp_tx_tvalid && arp_tx_tready && arp_tx_tlast) c_arp_tx <= c_arp_tx + 1;
            if (icmp_rx_tvalid && icmp_rx_tready && icmp_rx_tlast) c_icmp_rx <= c_icmp_rx + 1;
            if (icmp_tx_tvalid && icmp_tx_tready && icmp_tx_tlast) c_icmp_tx <= c_icmp_tx + 1;
            // stream down: the output has not moved for 2^16 cycles with data waiting
            if (!m_net_tvalid || m_net_tready)
                stall <= 0;
            else if (!stall[16])
                stall <= stall + 1;
        end
    end

    always_comb begin
        m_stats = '0;
        m_stats.rx_pkg_counter = c_rx;
        m_stats.tx_pkg_counter = c_tx;
        m_stats.arp_rx_pkg_counter = c_arp_rx;
        m_stats.arp_tx_pkg_counter = c_arp_tx;
        m_stats.icmp_rx_pkg_counter = c_icmp_rx;
        m_stats.icmp_tx_pkg_counter = c_icmp_tx;
        m_stats.roce_rx_pkg_counter = e_rx;
        m_stats.roce_tx_pkg_counter = e_tx;
        m_stats.ibv_rx_pkg_counter = e_ibv_rx;
        m_stats.ibv_tx_pkg_counter = e_ibv_tx;
        m_stats.roce_psn_drop_counter = e_psn;
        m_stats.roce_retrans_counter = e_retrans;
        m_stats.axis_stream_down = stall[16];
    end

`ifdef ROCE_TRACE
    logic [15:0] tr_cnt = 0;
    always_ff @(posedge clk) begin
        tr_cnt <= tr_cnt + 1;
        if (tr_cnt == 0)
            $display("%t %m: state net v/r %b%b iph v/r %b%b arp v/r %b%b icmp v/r %b%b roce v/r %b%b",
                $time, s_net_tvalid, s_net_tready, n_tvalid, n_tready, arp_rx_tvalid, arp_rx_tready,
                icmp_rx_tvalid, icmp_rx_tready, roce_rx_tvalid, roce_rx_tready);
    end
`endif

    assign m_stats2[0] = e_crc;
    assign m_stats2[1] = e_held;
    assign m_stats2[2] = e_trim;
    assign m_stats2[3] = e_stray;
    assign m_stats2[4] = 32'd0;
    assign m_stats2[5] = 32'd0;
    assign m_stats2[6] = 32'd0;
    assign m_stats2[7] = 32'd0;
endmodule
