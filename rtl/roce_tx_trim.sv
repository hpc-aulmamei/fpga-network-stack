`timescale 1ns / 1ps

// Cuts every packet the rocev2 transport sends to the length its IPv4 header
// gives, minus the 4 ICRC bytes that icrc_core appends next. The transport
// leaves room for the ICRC in the IP and UDP lengths but does not send it,
// and it zero-pads some packets (READ requests) past their end; the ICRC
// must cover exactly the packet. Beats after the cut, up to the input TLAST,
// are dropped.
//
// Input: IPv4 packets, header in the first beat (total length in bytes 2-3,
// big endian), keep contiguous from byte 0. Registered output.
module roce_tx_trim #(
    parameter integer DATA_BITS = 1024
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

    output logic [31:0]            stat_trimmed     // packets that lost bytes
);
    localparam integer BYTES = DATA_BITS / 8;
    localparam integer CB = $clog2(BYTES) + 1;

    logic        first = 1'b1;          // the next beat starts a packet
    logic        dropping;              // past the cut, waiting for TLAST
    logic [15:0] left;                  // bytes still to send after this packet's earlier beats

    wire [15:0] ip_len = {s_tdata[23:16], s_tdata[31:24]};
    // bytes to send from the current beat on
    wire [15:0] want = first ? ip_len - 16'd4 : left;
    wire        cut_here = want <= BYTES;   // the packet ends in this beat
    wire [CB-1:0] n = cut_here ? CB'(want) : CB'(BYTES);

    logic [BYTES-1:0] keep_n;
    always_comb
        for (int i = 0; i < BYTES; i++)
            keep_n[i] = i < n;

    wire out_free = !m_tvalid || m_tready;
    assign s_tready = out_free;
    wire fire = s_tvalid && s_tready;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            first <= 1'b1;
            dropping <= 1'b0;
            left <= 0;
            m_tvalid <= 1'b0;
            stat_trimmed <= 0;
        end else begin
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;
            if (fire) begin
                first <= s_tlast;
                if (dropping) begin
                    // padding after the cut
                    if (s_tlast)
                        dropping <= 1'b0;
                end else begin
                    m_tvalid <= 1'b1;
                    left <= want - BYTES;
                    if (cut_here && !s_tlast)
                        dropping <= 1'b1;
                    if (cut_here && (!s_tlast || (s_tkeep & ~keep_n) != 0))
                        stat_trimmed <= stat_trimmed + 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (fire && !dropping) begin
            m_tdata <= s_tdata;
            // a beat that ends before the cut keeps its own end
            m_tkeep <= s_tkeep & keep_n;
            m_tlast <= s_tlast || cut_here;
        end
    end
endmodule
