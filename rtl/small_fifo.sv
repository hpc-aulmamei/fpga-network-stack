`timescale 1ns / 1ps

// First-word-fall-through FIFO in registers / LUT RAM, with an occupancy count.
module small_fifo #(
    parameter integer DATA_BITS = 32,
    parameter integer DEPTH_BITS = 2
) (
    input  wire                  clk,
    input  wire                  resetn,

    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire [DATA_BITS-1:0]  s_data,

    output wire                  m_valid,
    input  wire                  m_ready,
    output wire [DATA_BITS-1:0]  m_data,

    output wire [DEPTH_BITS:0]   count
);
    localparam integer DEPTH = 1 << DEPTH_BITS;

    reg [DATA_BITS-1:0] mem [0:DEPTH-1];
    reg [DEPTH_BITS:0] wr_ptr = 0, rd_ptr = 0;

    assign count = wr_ptr - rd_ptr;
    assign s_ready = count != DEPTH;
    assign m_valid = count != 0;
    assign m_data = mem[rd_ptr[DEPTH_BITS-1:0]];

    always @(posedge clk) begin
        if (s_valid && s_ready)
            mem[wr_ptr[DEPTH_BITS-1:0]] <= s_data;
    end

    always @(posedge clk) begin
        if (!resetn) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (s_valid && s_ready)
                wr_ptr <= wr_ptr + 1;
            if (m_valid && m_ready)
                rd_ptr <= rd_ptr + 1;
        end
    end
endmodule
