`timescale 1ns / 1ps

// Spaces the RoCE ACK packets that enter the rocev2 transport at least
// GAP_CYCLES apart. The transport's retransmitter needs several cycles per
// ACK; ACKs back to back overrun it. At 200G a node receives an ACK for
// every 4 KiB WRITE (about 40 cycles at 230 MHz), so GAP_CYCLES must stay
// below that (20 measured clean on hardware, Alveo V80).
//
// A packet is an ACK if its first beat is IPv4 (version 4, IHL 5) / UDP to
// port 4791 with BTH opcode RC_ACK (0x11). Only first beats are inspected.
// Holding an ACK holds everything behind it.
module roce_ack_pacer #(
    parameter integer DATA_BITS = 1024,
    parameter integer GAP_CYCLES = 20
) (
    input  logic                   clk,
    input  logic                   resetn,

    input  logic                   s_tvalid,
    output logic                   s_tready,
    input  logic [DATA_BITS-1:0]   s_tdata,
    input  logic [DATA_BITS/8-1:0] s_tkeep,
    input  logic                   s_tlast,

    output logic                   m_tvalid,
    input  logic                   m_tready,
    output logic [DATA_BITS-1:0]   m_tdata,
    output logic [DATA_BITS/8-1:0] m_tkeep,
    output logic                   m_tlast,

    output logic [31:0]            stat_held        // cycles an ACK was held
);
    function automatic logic [7:0] byte_at(input logic [DATA_BITS-1:0] d, input integer i);
        return d[8 * i +: 8];
    endfunction

    logic first;
    logic [7:0] since;                  // cycles since the last ACK went in (saturates)

    wire is_ack = byte_at(s_tdata, 0) == 8'h45 && byte_at(s_tdata, 9) == 8'h11 &&
                  byte_at(s_tdata, 22) == 8'h12 && byte_at(s_tdata, 23) == 8'hB7 &&
                  byte_at(s_tdata, 28) == 8'h11;
    wire ack_start = s_tvalid && first && is_ack;
    wire hold = ack_start && since < GAP_CYCLES;

    wire out_free = !m_tvalid || m_tready;
    assign s_tready = out_free && !hold;
    wire fire = s_tvalid && s_tready;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            first <= 1'b1;
            since <= 8'hff;
            m_tvalid <= 1'b0;
            stat_held <= 0;
        end else begin
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;
            if (fire) begin
                first <= s_tlast;
                m_tvalid <= 1'b1;
            end
            if (fire && ack_start)
                since <= 8'd1;
            else if (since != 8'hff)
                since <= since + 1'b1;
            if (hold)
                stat_held <= stat_held + 1;
        end
    end

    always_ff @(posedge clk)
        if (fire) begin
            m_tdata <= s_tdata;
            m_tkeep <= s_tkeep;
            m_tlast <= s_tlast;
        end
endmodule
