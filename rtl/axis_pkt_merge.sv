`timescale 1ns / 1ps

// axis_pkt_merge: N:1 packet merger (Versal has no AXI4-Stream Interconnect
// IP). Round robin between the inputs, a whole packet at a time, registered
// output; one idle cycle between packets.
module axis_pkt_merge #(
    parameter integer N = 2,
    parameter integer DATA_BITS = 1024
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire [N-1:0]                 s_tvalid,
    output wire [N-1:0]                 s_tready,
    input  wire [N*DATA_BITS-1:0]       s_tdata,
    input  wire [N*DATA_BITS/8-1:0]     s_tkeep,
    input  wire [N-1:0]                 s_tlast,
    output reg                          m_tvalid = 1'b0,
    input  wire                         m_tready,
    output reg  [DATA_BITS-1:0]         m_tdata,
    output reg  [DATA_BITS/8-1:0]       m_tkeep,
    output reg                          m_tlast
);
    localparam integer SB = (N > 1) ? $clog2(N) : 1;

    // power-up values, usable before the first reset
    reg          locked = 1'b0;
    reg [SB-1:0] sel = 0, last_sel = N - 1;
    wire         out_free = !m_tvalid || m_tready;

    // next input with data, after the one served last
    reg [SB-1:0] pick;
    reg          pick_valid;
    integer i;
    always @(*) begin
        pick = last_sel;
        pick_valid = 1'b0;
        for (i = N; i >= 1; i = i - 1) begin
            if (s_tvalid[(last_sel + i) % N]) begin
                pick = (last_sel + i) % N;
                pick_valid = 1'b1;
            end
        end
    end

    genvar g;
    for (g = 0; g < N; g = g + 1) begin : g_ready
        assign s_tready[g] = locked && (sel == g) && out_free;
    end

    wire take = locked && out_free && s_tvalid[sel];

    always @(posedge clk) begin
        if (!resetn) begin
            locked <= 1'b0;
            sel <= 0;
            last_sel <= N - 1;
            m_tvalid <= 1'b0;
        end else begin
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;
            if (!locked) begin
                if (pick_valid) begin
                    locked <= 1'b1;
                    sel <= pick;
                end
            end else if (take) begin
                m_tvalid <= 1'b1;
                m_tdata <= s_tdata[sel*DATA_BITS +: DATA_BITS];
                m_tkeep <= s_tkeep[sel*DATA_BITS/8 +: DATA_BITS/8];
                m_tlast <= s_tlast[sel];
                if (s_tlast[sel]) begin
                    locked <= 1'b0;
                    last_sel <= sel;
                end
            end
        end
    end
endmodule
