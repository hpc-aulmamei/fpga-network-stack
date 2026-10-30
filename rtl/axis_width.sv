`timescale 1ns / 1ps

// AXI4-Stream width converters between the stack's DATA_BITS stream and the
// 64-bit icmp_server. Keep is contiguous from byte 0 within a beat, and only
// the last beat of a packet may be partial.

// axis_narrow: one WIDE beat -> up to WIDE/NARROW beats, words without
// valid bytes skipped.
module axis_narrow #(
    parameter integer WIDE = 1024,
    parameter integer NARROW = 64
) (
    input  logic                clk,
    input  logic                resetn,

    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic [WIDE-1:0]     s_tdata,
    input  logic [WIDE/8-1:0]   s_tkeep,
    input  logic                s_tlast,

    output logic                m_tvalid,
    input  logic                m_tready,
    output logic [NARROW-1:0]   m_tdata,
    output logic [NARROW/8-1:0] m_tkeep,
    output logic                m_tlast
);
    localparam integer N = WIDE / NARROW;
    localparam integer NB = NARROW / 8;
    localparam integer IB = $clog2(N);

    logic [IB-1:0] idx;
    wire [NB-1:0] keep_i = s_tkeep[NB * idx +: NB];
    // the last word of this beat: the next one has no valid byte
    wire [WIDE/8:0] keep_ext = {1'b0, s_tkeep};
    wire last_word = !keep_ext[NB * (int'(idx) + 1)];

    assign m_tvalid = s_tvalid;
    assign m_tdata = s_tdata[NARROW * idx +: NARROW];
    assign m_tkeep = keep_i;
    assign m_tlast = s_tlast && last_word;
    assign s_tready = m_tready && last_word;

    always_ff @(posedge clk) begin
        if (!resetn)
            idx <= '0;
        else if (m_tvalid && m_tready)
            idx <= last_word ? '0 : idx + 1'b1;
    end
endmodule

// axis_widen: NARROW beats packed into WIDE beats, flushed at TLAST.
module axis_widen #(
    parameter integer WIDE = 1024,
    parameter integer NARROW = 64
) (
    input  logic                clk,
    input  logic                resetn,

    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic [NARROW-1:0]   s_tdata,
    input  logic [NARROW/8-1:0] s_tkeep,
    input  logic                s_tlast,

    output logic                m_tvalid,
    input  logic                m_tready,
    output logic [WIDE-1:0]     m_tdata,
    output logic [WIDE/8-1:0]   m_tkeep,
    output logic                m_tlast
);
    localparam integer N = WIDE / NARROW;
    localparam integer NB = NARROW / 8;
    localparam integer IB = $clog2(N);

    logic [IB-1:0] idx;
    assign s_tready = !m_tvalid || m_tready;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            idx <= '0;
            m_tvalid <= 1'b0;
            m_tkeep <= '0;
        end else begin
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tkeep <= '0;
            end
            if (s_tvalid && s_tready) begin
                m_tdata[NARROW * idx +: NARROW] <= s_tdata;
                if (m_tvalid && m_tready)
                    m_tkeep <= (WIDE/8)'(s_tkeep) << (NB * idx);
                else
                    m_tkeep[NB * idx +: NB] <= s_tkeep;
                m_tlast <= s_tlast;
                if (s_tlast || idx == N - 1) begin
                    m_tvalid <= 1'b1;
                    idx <= '0;
                end else
                    idx <= idx + 1'b1;
            end
        end
    end
endmodule
