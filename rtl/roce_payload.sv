`timescale 1ns / 1ps

import roce_pkg::*;

// Payload side of the rocev2 transport.
//
// Read commands (m_axis_mem_read_cmd) ask for the payload of an outgoing
// packet; the transport takes the data on one stream (s_axis_mem_read_data)
// in command order, a packet per command, ending with TLAST:
//   - READ response (RC_RDMA_READ_RESP_*): from the payload source
//   - WRITE / SEND, actv = 1 (PKG_NR): from the payload source, and the same beats go
//     into the WRITE's slot of the retransmission buffer (QPs below
//     2^RT_QP_BITS); the command's offs is the slot
//   - WRITE / SEND, actv = 0 (PKG_R, a retransmission): from that slot of the
//     retransmission buffer; for the other QPs from the payload source again
//     (the command has the WRITE's local address), which must still hold it
// An order FIFO remembers the source of each command for the data mux.
//
// Write commands (m_axis_mem_write_cmd: incoming WRITE and READ response
// payload) go to the payload sink as they are.
module roce_payload #(
    parameter integer DATA_BITS = 1024,
    parameter integer RT_QP_BITS = 3
) (
    input  logic          clk,
    input  logic          resetn,

    // transport read commands and payload
    input  logic          s_rdcmd_valid,
    output logic          s_rdcmd_ready,
    input  mem_cmd_hls_t  s_rdcmd_data,

    output logic          m_tvalid,
    input  logic          m_tready,
    output logic [DATA_BITS-1:0] m_tdata,
    output logic [DATA_BITS/8-1:0] m_tkeep,
    output logic          m_tlast,

    // payload source
    output logic          m_src_valid,
    input  logic          m_src_ready,
    output mem_req_t      m_src_data,

    input  logic          s_src_tvalid,
    output logic          s_src_tready,
    input  logic [DATA_BITS-1:0] s_src_tdata,
    input  logic [DATA_BITS/8-1:0] s_src_tkeep,
    input  logic          s_src_tlast,

    // retransmission buffer (roce_retrans_mem command format)
    output logic          m_rtw_cmd_valid,
    input  logic          m_rtw_cmd_ready,
    output logic [95:0]   m_rtw_cmd_data,
    output logic          m_rtw_tvalid,
    input  logic          m_rtw_tready,
    output logic [DATA_BITS-1:0] m_rtw_tdata,
    output logic          m_rtw_tlast,

    output logic          m_rtr_cmd_valid,
    input  logic          m_rtr_cmd_ready,
    output logic [95:0]   m_rtr_cmd_data,
    input  logic          s_rtr_tvalid,
    output logic          s_rtr_tready,
    input  logic [DATA_BITS-1:0] s_rtr_tdata,
    input  logic [DATA_BITS/8-1:0] s_rtr_tkeep,
    input  logic          s_rtr_tlast,

    // transport write commands -> payload sink
    input  logic          s_wrcmd_valid,
    output logic          s_wrcmd_ready,
    input  mem_cmd_hls_t  s_wrcmd_data,
    output logic          m_snk_valid,
    input  logic          m_snk_ready,
    output mem_req_t      m_snk_data
);
    // ---------------- read commands ----------------
    logic         c_valid, c_ready;
    mem_cmd_hls_t c;

    axis_skid #(.DATA_BITS($bits(mem_cmd_hls_t))) inst_cmd_slice (
        .clk(clk), .resetn(resetn),
        .s_valid(s_rdcmd_valid), .s_ready(s_rdcmd_ready), .s_data(s_rdcmd_data),
        .m_valid(c_valid), .m_ready(c_ready), .m_data(c)
    );

    wire [4:0] c_op = c.op_code[4:0];
    wire       c_write = is_write_op(c_op);
    wire       c_buffered = c.qpn < (1 << RT_QP_BITS);
    wire       c_retrans = !c.actv && c_write && c_buffered;
    wire       c_mirror = c.actv && c_write && c_buffered;
    // slot address in the retransmission buffer: QP in bits 17 and up, slot in 16:12
    wire [63:0] c_rt_addr = 64'(c.qpn[RT_QP_BITS-1:0]) << 17 | 64'(c.offs[4:0]) << 12;

    logic       ord_in_ready;
    wire        tgt_ready = c_retrans ? m_rtr_cmd_ready : m_src_ready;
    wire        mir_ready = !c_mirror || m_rtw_cmd_ready;
    assign c_ready = ord_in_ready && tgt_ready && mir_ready;
    wire        c_go = c_valid && c_ready;

    assign m_src_valid = c_valid && !c_retrans && ord_in_ready && mir_ready;
    assign m_rtr_cmd_valid = c_valid && c_retrans && ord_in_ready;
    assign m_rtw_cmd_valid = c_valid && c_mirror && ord_in_ready && m_src_ready;

    always_comb begin
        m_src_data = '0;
        m_src_data.opcode = c_op;
        m_src_data.qpn = c.qpn[5:0];
        m_src_data.last = c.lst;
        m_src_data.vaddr = c.addr;
        m_src_data.len = c.len;
    end
    assign m_rtr_cmd_data = {4'd0, c.len, c_rt_addr};
    assign m_rtw_cmd_data = {4'd0, c.len, c_rt_addr};

    // ---------------- data in command order ----------------
    logic ord_valid, ord_pop;
    logic [1:0] ord;                            // [0] from the retransmission buffer, [1] mirrored
    small_fifo #(.DATA_BITS(2), .DEPTH_BITS(4)) inst_order (
        .clk(clk), .resetn(resetn),
        .s_valid(c_go), .s_ready(ord_in_ready), .s_data({c_mirror, c_retrans}),
        .m_valid(ord_valid), .m_ready(ord_pop), .m_data(ord), .count()
    );

    wire from_rt = ord[0];
    wire mirror = ord[1];

    logic          o_valid, o_ready;
    logic [DATA_BITS-1:0] o_data;
    logic [DATA_BITS/8-1:0] o_keep;
    logic          o_last;

    wire in_valid = from_rt ? s_rtr_tvalid : s_src_tvalid;
    assign o_data = from_rt ? s_rtr_tdata : s_src_tdata;
    assign o_keep = from_rt ? s_rtr_tkeep : s_src_tkeep;
    assign o_last = from_rt ? s_rtr_tlast : s_src_tlast;

    wire side_ready = !mirror || m_rtw_tready;
    assign o_valid = ord_valid && in_valid && side_ready;
    wire fire = o_valid && o_ready;
    assign s_src_tready = ord_valid && !from_rt && o_ready && side_ready;
    assign s_rtr_tready = ord_valid && from_rt && o_ready;
    assign ord_pop = fire && o_last;

    assign m_rtw_tvalid = ord_valid && mirror && s_src_tvalid && o_ready;
    assign m_rtw_tdata = s_src_tdata;
    assign m_rtw_tlast = s_src_tlast;

    axis_skid #(.DATA_BITS(DATA_BITS + DATA_BITS / 8 + 1)) inst_out_slice (
        .clk(clk), .resetn(resetn),
        .s_valid(o_valid), .s_ready(o_ready), .s_data({o_last, o_keep, o_data}),
        .m_valid(m_tvalid), .m_ready(m_tready), .m_data({m_tlast, m_tkeep, m_tdata})
    );

    // ---------------- write commands ----------------
    assign m_snk_valid = s_wrcmd_valid;
    assign s_wrcmd_ready = m_snk_ready;
    always_comb begin
        m_snk_data = '0;
        m_snk_data.opcode = s_wrcmd_data.op_code[4:0];
        m_snk_data.qpn = s_wrcmd_data.qpn[5:0];
        m_snk_data.last = s_wrcmd_data.lst;
        m_snk_data.vaddr = s_wrcmd_data.addr;
        m_snk_data.len = s_wrcmd_data.len;
    end

`ifdef ROCE_TRACE
    always_ff @(posedge clk) begin
        if (c_go)
            $display("%t %m: read cmd op %02x qp %0d addr %h len %0d actv %0d offs %0d lst %0d -> %s%s", $time,
                c_op, c.qpn, c.addr, c.len, c.actv, c.offs, c.lst, c_retrans ? "retrans" : "source", c_mirror ? " +mirror" : "");
        if (s_wrcmd_valid && s_wrcmd_ready)
            $display("%t %m: write cmd op %02x qp %0d addr %h len %0d lst %0d", $time,
                s_wrcmd_data.op_code[4:0], s_wrcmd_data.qpn, s_wrcmd_data.addr, s_wrcmd_data.len, s_wrcmd_data.lst);
        if (fire && o_last)
            $display("%t %m: payload packet done (%s)", $time, from_rt ? "retrans" : "source");
    end
`endif
endmodule
