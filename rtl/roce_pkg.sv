`timescale 1ns / 1ps

// Types and constants of the RDMA stack (rdma_stack): the interfaces between
// the HLS IPs of this repository (rocev2, ip_handler, mac_ip_encode,
// arp_server_subnet, icmp_server) and the RTL around them. None of them
// depends on the data width.
//
// The *_hls_t structs follow the HLS structs bit for bit: Vitis packs them
// with "aggregate compact=bit", first member in the least significant bits,
// enums 32 bits wide; the TDATA of the IP ports is that packing, padded to a
// multiple of 8 bits. A SystemVerilog packed struct lists its members from
// the most significant end, so they appear here in reverse order.
package roce_pkg;

    localparam integer PMTU = 4096;

    // InfiniBand RC opcodes (BTH), as ibOpCode in ib_transport_protocol.hpp
    localparam logic [4:0] RC_SEND_FIRST = 5'h00;
    localparam logic [4:0] RC_SEND_MIDDLE = 5'h01;
    localparam logic [4:0] RC_SEND_LAST = 5'h02;
    localparam logic [4:0] RC_SEND_ONLY = 5'h04;
    localparam logic [4:0] RC_RDMA_WRITE_FIRST = 5'h06;
    localparam logic [4:0] RC_RDMA_WRITE_MIDDLE = 5'h07;
    localparam logic [4:0] RC_RDMA_WRITE_LAST = 5'h08;
    localparam logic [4:0] RC_RDMA_WRITE_ONLY = 5'h0A;
    localparam logic [4:0] RC_RDMA_READ_REQUEST = 5'h0C;
    localparam logic [4:0] RC_RDMA_READ_RESP_FIRST = 5'h0D;
    localparam logic [4:0] RC_RDMA_READ_RESP_MIDDLE = 5'h0E;
    localparam logic [4:0] RC_RDMA_READ_RESP_LAST = 5'h0F;
    localparam logic [4:0] RC_RDMA_READ_RESP_ONLY = 5'h10;
    localparam logic [4:0] RC_ACK = 5'h11;

    function automatic logic is_write_op(input logic [4:0] op);
        return op == RC_RDMA_WRITE_FIRST || op == RC_RDMA_WRITE_MIDDLE ||
               op == RC_RDMA_WRITE_LAST || op == RC_RDMA_WRITE_ONLY ||
               op == RC_SEND_FIRST || op == RC_SEND_MIDDLE ||
               op == RC_SEND_LAST || op == RC_SEND_ONLY;
    endfunction

    function automatic logic is_read_resp_op(input logic [4:0] op);
        return op == RC_RDMA_READ_RESP_FIRST || op == RC_RDMA_READ_RESP_MIDDLE ||
               op == RC_RDMA_READ_RESP_LAST || op == RC_RDMA_READ_RESP_ONLY;
    endfunction

    // HLS addresses are in network byte order with the first octet in bits
    // 7:0; the node's registers keep the first octet in the top bits
    function automatic logic [31:0] bswap32(input logic [31:0] v);
        return {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction

    function automatic logic [47:0] bswap48(input logic [47:0] v);
        return {v[7:0], v[15:8], v[23:16], v[31:24], v[39:32], v[47:40]};
    endfunction

    // ------------------------------------------------------------------
    // HLS interface structs (rocev2_top)
    // ------------------------------------------------------------------

    // txMeta: s_axis_sq_meta (248 bits)
    typedef struct packed {
        logic [31:0] imm;
        logic [31:0] len;
        logic [63:0] laddr;
        logic [63:0] raddr;
        logic [5:0]  offs;      // window slot of a WRITE
        logic        lst;
        logic        host;
        logic [15:0] qpn;
        logic [31:0] op_code;
    } tx_meta_hls_t;

    // ackMeta: m_axis_rx_ack_meta (63 bits in 64)
    typedef struct packed {
        logic        pad;
        logic        cum;       // a WRITE completion from the retransmitter
        logic [5:0]  offs;      // its window slot
        logic        lst;
        logic [1:0]  strm;
        logic [3:0]  dst;
        logic        host;
        logic [15:0] qpn;
        logic [31:0] op_code;   // RC_ACK, or the READ response that completed a READ
    } ack_meta_hls_t;

    // memCmd: m_axis_mem_read_cmd / m_axis_mem_write_cmd (139 bits in 144)
    typedef struct packed {
        logic [4:0]  pad;
        logic [5:0]  offs;
        logic        host;
        logic        actv;      // read command of a WRITE: 0 = retransmission (PKG_R), 1 = first send (PKG_NR)
        logic [27:0] len;
        logic [1:0]  strm;
        logic [3:0]  dst;
        logic [47:0] addr;
        logic        lst;
        logic [15:0] qpn;
        logic [31:0] op_code;
    } mem_cmd_hls_t;

    // qpContext: s_axis_qp_interface (184 bits)
    typedef struct packed {
        logic [47:0] vaddr;
        logic [31:0] r_key;
        logic [23:0] local_psn;
        logic [23:0] remote_psn;
        logic [23:0] qp_num;
        logic [31:0] new_state; // qpState: 2 = READY_RECV
    } qp_ctx_hls_t;

    // ifConnReq: s_axis_qp_conn_interface (184 bits)
    typedef struct packed {
        logic [15:0]  remote_udp_port;
        logic [127:0] remote_ip_address;
        logic [23:0]  remote_qpn;
        logic [15:0]  local_qpn;
    } qp_conn_hls_t;

    // arpTableReply: mac_ip_encode / host ARP lookup reply (49 bits in 56)
    typedef struct packed {
        logic [6:0]  pad;
        logic        hit;
        logic [47:0] mac;
    } arp_reply_hls_t;

    // ------------------------------------------------------------------
    // stack interfaces
    // ------------------------------------------------------------------

    // send queue request (user -> roce_engine): at most one PMTU
    typedef struct packed {
        logic [27:0] len;
        logic [47:0] raddr;     // remote virtual address
        logic [47:0] laddr;     // local address (payload source / sink)
        logic [5:0]  qpn;
        logic [4:0]  op;        // RC_RDMA_WRITE_ONLY or RC_RDMA_READ_REQUEST
    } sq_req_t;

    // payload request (roce_engine -> payload source / sink)
    typedef struct packed {
        logic [27:0] len;
        logic [47:0] vaddr;
        logic        last;      // last packet of a message
        logic [5:0]  qpn;
        logic [4:0]  opcode;
    } mem_req_t;

    // completion (roce_engine -> user), 32 bits
    typedef struct packed {
        logic [7:0]  rsvd;
        logic        cum;       // WRITE completion
        logic [5:0]  slot;      // its window slot
        logic [5:0]  rsvd2;
        logic [5:0]  qpn;
        logic [4:0]  opcode;    // RC_ACK (WRITE) or RC_RDMA_READ_RESP_* (READ)
    } ack_t;

    // network statistics
    typedef struct packed {
        logic [31:0] rx_pkg_counter;
        logic [31:0] tx_pkg_counter;
        logic [31:0] arp_rx_pkg_counter;
        logic [31:0] arp_tx_pkg_counter;
        logic [31:0] icmp_rx_pkg_counter;
        logic [31:0] icmp_tx_pkg_counter;
        logic [31:0] tcp_rx_pkg_counter;
        logic [31:0] tcp_tx_pkg_counter;
        logic [31:0] roce_rx_pkg_counter;
        logic [31:0] roce_tx_pkg_counter;
        logic [31:0] ibv_rx_pkg_counter;
        logic [31:0] ibv_tx_pkg_counter;
        logic [31:0] roce_psn_drop_counter;
        logic [31:0] roce_retrans_counter;
        logic [15:0] tcp_session_counter;
        logic        axis_stream_down;
    } net_stat_t;

endpackage
