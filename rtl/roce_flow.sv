`timescale 1ns / 1ps

import roce_pkg::*;

// Send queue admission and completions of the rocev2 transport.
//
// WRITEs: every QP has a window of WR_WINDOW slots, handed out in order. A
// WRITE takes the next slot (txMeta.offs); its payload is kept in that slot
// of the retransmission buffer until the transport's retransmitter releases
// it. The retransmitter reports every released WRITE once, in PSN order, as
// an ackMeta with cum = 1 and the slot: everything from the oldest slot up
// to that one is free again. A WRITE waits while its QP's window is full.
//
// READs: at most RD_WINDOW per QP in flight. The transport reports a READ as
// complete with the ackMeta of its READ_RESP_ONLY / _LAST packet (cum = 0).
//
// Every ackMeta is one completion for the user. One event per cycle:
// completions first, then the next send queue request.
module roce_flow #(
    parameter integer QP_BITS = 6,
    parameter integer WR_WINDOW = 32,           // <= the retransmission buffer slots
    parameter integer RD_WINDOW = 32
) (
    input  logic          clk,
    input  logic          resetn,

    input  logic          s_sq_valid,
    output logic          s_sq_ready,
    input  sq_req_t       s_sq_data,

    output logic          m_meta_valid,
    input  logic          m_meta_ready,
    output tx_meta_hls_t  m_meta_data,

    input  logic          s_ack_valid,
    output logic          s_ack_ready,
    input  ack_meta_hls_t s_ack_data,

    output logic          m_ack_valid,
    output ack_t          m_ack_data,

    output logic [31:0]   stat_stray_acks       // completions that matched nothing outstanding
);
    localparam integer NQP = 1 << QP_BITS;
    localparam integer SB = $clog2(WR_WINDOW);
    localparam integer WB = $clog2(WR_WINDOW + 1);
    localparam integer RB = $clog2(RD_WINDOW + 1);

    logic [SB-1:0] wr_head [NQP];               // oldest outstanding slot
    logic [WB-1:0] wr_count [NQP];
    logic [RB-1:0] rd_count [NQP];

    // ---------------- input registers ----------------
    // completions: always taken, registered once
    logic          a_valid;
    ack_meta_hls_t a_data;
    assign s_ack_ready = 1'b1;
    always_ff @(posedge clk) begin
        a_valid <= resetn && s_ack_valid;
        a_data <= s_ack_data;
    end

    wire [4:0]         a_op = a_data.op_code[4:0];
    wire [QP_BITS-1:0] a_qp = a_data.qpn[QP_BITS-1:0];
    wire               a_wr = a_data.cum && a_op == RC_ACK;
    wire               a_rd = !a_data.cum && (a_op == RC_RDMA_READ_RESP_ONLY || a_op == RC_RDMA_READ_RESP_LAST);
    // slots released by a WRITE completion: oldest .. offs
    wire [SB-1:0]      a_slot = a_data.offs[SB-1:0];
    wire [WB-1:0]      a_n = WB'(SB'(a_slot - wr_head[a_qp])) + 1'b1;
    wire               a_wr_ok = a_n <= wr_count[a_qp];
    wire               a_rd_ok = rd_count[a_qp] != 0;

    // send queue: one request held in a register
    logic    q_valid;
    sq_req_t q;
    wire [QP_BITS-1:0] q_qp = q.qpn[QP_BITS-1:0];
    wire     q_read = q.op == RC_RDMA_READ_REQUEST;
    wire     q_room = q_read ? (rd_count[q_qp] < RD_WINDOW) : (wr_count[q_qp] < WR_WINDOW);
    wire [SB-1:0] q_slot = SB'(wr_head[q_qp] + wr_count[q_qp]);

    wire out_free = !m_meta_valid || m_meta_ready;
    // a cycle with a completion does not post: no two updates of one QP at once
    wire post = q_valid && q_room && out_free && !a_valid;
    assign s_sq_ready = !q_valid || post;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            q_valid <= 1'b0;
            m_meta_valid <= 1'b0;
            m_ack_valid <= 1'b0;
            stat_stray_acks <= 0;
            for (int i = 0; i < NQP; i++) begin
                wr_head[i] <= '0;
                wr_count[i] <= '0;
                rd_count[i] <= '0;
            end
        end else begin
            if (s_sq_valid && s_sq_ready) begin
                q_valid <= 1'b1;
                q <= s_sq_data;
            end else if (post)
                q_valid <= 1'b0;

            if (m_meta_valid && m_meta_ready)
                m_meta_valid <= 1'b0;

            m_ack_valid <= 1'b0;
            if (a_valid) begin
                m_ack_valid <= 1'b1;
                if (a_wr) begin
                    if (a_wr_ok) begin
                        wr_head[a_qp] <= a_slot + 1'b1;
                        wr_count[a_qp] <= wr_count[a_qp] - a_n;
                    end else
                        stat_stray_acks <= stat_stray_acks + 1;
                end else if (a_rd) begin
                    if (a_rd_ok)
                        rd_count[a_qp] <= rd_count[a_qp] - 1'b1;
                    else
                        stat_stray_acks <= stat_stray_acks + 1;
                end
            end else if (post) begin
                m_meta_valid <= 1'b1;
                if (q_read)
                    rd_count[q_qp] <= rd_count[q_qp] + 1'b1;
                else
                    wr_count[q_qp] <= wr_count[q_qp] + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (post) begin
            m_meta_data <= '0;
            m_meta_data.op_code <= {27'd0, q.op};
            m_meta_data.qpn <= {{(16 - 6){1'b0}}, q.qpn};
            m_meta_data.host <= 1'b1;
            m_meta_data.lst <= 1'b1;
            m_meta_data.offs <= q_read ? 6'd0 : 6'(q_slot);
            m_meta_data.raddr <= {16'd0, q.raddr};
            m_meta_data.laddr <= {16'd0, q.laddr};
            m_meta_data.len <= {4'd0, q.len};
        end
        if (a_valid) begin
            m_ack_data <= '0;
            m_ack_data.opcode <= a_op;
            m_ack_data.qpn <= a_data.qpn[5:0];
            m_ack_data.slot <= a_data.offs;
            m_ack_data.cum <= a_data.cum;
        end
    end

`ifdef ROCE_TRACE
    always_ff @(posedge clk) begin
        if (post)
            $display("%t %m: post op %02x qp %0d laddr %h raddr %h len %0d slot %0d", $time,
                q.op, q.qpn, q.laddr, q.raddr, q.len, q_slot);
        if (a_valid)
            $display("%t %m: completion op %02x qp %0d offs %0d cum %0d", $time,
                a_op, a_data.qpn, a_data.offs, a_data.cum);
    end
`endif
endmodule
