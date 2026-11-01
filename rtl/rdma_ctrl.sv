`timescale 1ns / 1ps

// AXI4-Lite registers of the RDMA stack (rdma_stack): addresses, ARP, QP
// setup, a send queue fed from registers, completions and the counters.
// doc/rdma_stack.md has the register map.
//
// The bus may repeat a write and split a read in two (PCIe paths do both), so
// nothing changes state on a read, a repeated configuration write only sends
// the same configuration again, and SQ_POST queues a message only when the
// value written differs from the last one. Registers take whole 32-bit writes
// (all byte strobes); other writes are answered and ignored. sq_push sees
// sq_push_ready a cycle late, but only one write is in flight and the FIFO
// pops independently, so the room checked on the write is still there.
module rdma_ctrl #(
    parameter integer DATA_BITS = 1024,
    parameter integer RT_QP_BITS = 3,
    parameter integer WR_WINDOW = 32,
    parameter integer RD_WINDOW = 32,
    parameter integer NSTATS = 17
) (
    input  wire                  clk,
    input  wire                  resetn,

    input  wire [11:0]           s_axil_awaddr,
    input  wire                  s_axil_awvalid,
    output reg                   s_axil_awready,
    input  wire [31:0]           s_axil_wdata,
    input  wire [3:0]            s_axil_wstrb,
    input  wire                  s_axil_wvalid,
    output reg                   s_axil_wready,
    output wire [1:0]            s_axil_bresp,
    output reg                   s_axil_bvalid,
    input  wire                  s_axil_bready,
    input  wire [11:0]           s_axil_araddr,
    input  wire                  s_axil_arvalid,
    output reg                   s_axil_arready,
    output reg  [31:0]           s_axil_rdata,
    output wire [1:0]            s_axil_rresp,
    output reg                   s_axil_rvalid,
    input  wire                  s_axil_rready,

    output reg  [47:0]           local_mac,
    output reg  [31:0]           local_ip,

    // ARP lookup, IPv4 address (first octet in bits 31:24)
    output reg                   m_arp_valid,
    input  wire                  m_arp_ready,
    output reg  [31:0]           m_arp_data,

    // QP setup, the 8-word format of rdma_stack
    output reg                   m_qp_valid,
    input  wire                  m_qp_ready,
    output wire [255:0]          m_qp_data,

    // send queue, the 6-word format of rdma_stack
    output wire                  m_sq_valid,
    input  wire                  m_sq_ready,
    output wire [191:0]          m_sq_data,

    // requests handed to the transport (any source) and completions
    input  wire                  sq_req,
    input  wire                  cq_valid,
    input  wire [31:0]           cq_data,

    input  wire [NSTATS*32-1:0]  stats,
    input  wire                  tx_stalled
);
    localparam [31:0] ID = 32'h5244_4D41;           // "RDMA"
    localparam [31:0] VERSION = 32'h0001_0000;      // 1.0

    assign s_axil_bresp = 2'b00;
    assign s_axil_rresp = 2'b00;

    // ---------------------------------------------------------------- registers
    reg [31:0] scratch;
    reg [63:0] cycles;
    reg [15:0] qp_lqpn, qp_rport;
    reg [23:0] qp_rqpn, qp_lpsn, qp_rpsn;
    reg [31:0] qp_rip, qp_rkey;
    reg [1:0]  qp_mode;
    reg [31:0] sq_ctrl, sq_len, sq_db;
    reg [47:0] sq_laddr, sq_raddr;
    reg [63:0] sq_reqs, cq_count, cq_msgs;
    reg [31:0] cq_last;

    assign m_qp_data = {32'd0, qp_rkey, 16'd0, qp_rport, qp_rip, 8'd0, qp_rpsn, 8'd0, qp_lpsn,
                        8'd0, qp_rqpn, 14'd0, qp_mode, qp_lqpn};

    // register posts, 16 deep
    reg        sq_push;
    wire       sq_push_ready;
    wire [4:0] sq_count;

    small_fifo #(.DATA_BITS(192), .DEPTH_BITS(4)) inst_sq_q (
        .clk(clk), .resetn(resetn),
        .s_valid(sq_push), .s_ready(sq_push_ready),
        .s_data({16'd0, sq_raddr, 16'd0, sq_laddr, sq_len, sq_ctrl}),
        .m_valid(m_sq_valid), .m_ready(m_sq_ready), .m_data(m_sq_data), .count(sq_count)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            cycles <= 0;
            sq_reqs <= 0;
            cq_count <= 0;
            cq_msgs <= 0;
            cq_last <= 0;
        end else begin
            cycles <= cycles + 1;
            if (sq_req)
                sq_reqs <= sq_reqs + 1;
            if (cq_valid) begin
                cq_count <= cq_count + 1;
                cq_msgs <= cq_msgs + cq_data[1];
                cq_last <= cq_data;
            end
        end
    end

    // ---------------------------------------------------------------- read mux
    reg [11:0] r_addr;
    reg [31:0] reg_rdata;

    always @(*) begin
        case ({r_addr[11:2], 2'b00})
            12'h000: reg_rdata = ID;
            12'h004: reg_rdata = VERSION;
            12'h008: reg_rdata = {8'(RD_WINDOW), 8'(WR_WINDOW), 4'(RT_QP_BITS), 12'(DATA_BITS)};
            12'h00C: reg_rdata = scratch;
            12'h010: reg_rdata = cycles[31:0];
            12'h014: reg_rdata = cycles[63:32];
            12'h020: reg_rdata = local_mac[31:0];
            12'h024: reg_rdata = {16'd0, local_mac[47:32]};
            12'h028: reg_rdata = local_ip;
            12'h02C: reg_rdata = m_arp_data;
            12'h030: reg_rdata = {30'd0, m_qp_valid, m_arp_valid};
            12'h040: reg_rdata = {16'd0, qp_lqpn};
            12'h044: reg_rdata = {8'd0, qp_rqpn};
            12'h048: reg_rdata = {8'd0, qp_lpsn};
            12'h04C: reg_rdata = {8'd0, qp_rpsn};
            12'h050: reg_rdata = qp_rip;
            12'h054: reg_rdata = {16'd0, qp_rport};
            12'h058: reg_rdata = qp_rkey;
            12'h05C: reg_rdata = {30'd0, qp_mode};
            12'h080: reg_rdata = sq_ctrl;
            12'h084: reg_rdata = sq_len;
            12'h088: reg_rdata = sq_laddr[31:0];
            12'h08C: reg_rdata = {16'd0, sq_laddr[47:32]};
            12'h090: reg_rdata = sq_raddr[31:0];
            12'h094: reg_rdata = {16'd0, sq_raddr[47:32]};
            12'h098: reg_rdata = sq_db;
            12'h09C: reg_rdata = {23'd0, !sq_push_ready, 3'd0, sq_count};
            12'h0A0: reg_rdata = sq_reqs[31:0];
            12'h0A4: reg_rdata = sq_reqs[63:32];
            12'h100: reg_rdata = cq_count[31:0];
            12'h104: reg_rdata = cq_count[63:32];
            12'h108: reg_rdata = cq_msgs[31:0];
            12'h10C: reg_rdata = cq_msgs[63:32];
            12'h110: reg_rdata = cq_last;
            12'h1FC: reg_rdata = {31'd0, tx_stalled};
            default:
                if (r_addr[11:9] == 3'b001 && r_addr[8:2] < NSTATS)     // 0x200 + 4 i
                    reg_rdata = stats[r_addr[8:2] * 32 +: 32];
                else
                    reg_rdata = 32'd0;
        endcase
    end

    // ---------------------------------------------------------------- AXI4-Lite
    wire [11:0] w_reg = {s_axil_awaddr[11:2], 2'b00};

    always @(posedge clk) begin
        if (!resetn) begin
            s_axil_awready <= 1'b0;
            s_axil_wready <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_arready <= 1'b0;
            s_axil_rvalid <= 1'b0;
            m_arp_valid <= 1'b0;
            m_qp_valid <= 1'b0;
            sq_push <= 1'b0;
            scratch <= 0;
            local_mac <= 48'h02_00_00_00_00_00;
            local_ip <= 32'h0A_00_00_01;
            m_arp_data <= 0;
            qp_lqpn <= 0;
            qp_rqpn <= 0;
            qp_lpsn <= 0;
            qp_rpsn <= 0;
            qp_rip <= 0;
            qp_rport <= 0;
            qp_rkey <= 0;
            qp_mode <= 0;
            sq_ctrl <= 0;
            sq_len <= 0;
            sq_laddr <= 0;
            sq_raddr <= 0;
            sq_db <= 0;
        end else begin
            s_axil_awready <= 1'b0;
            s_axil_wready <= 1'b0;
            s_axil_arready <= 1'b0;
            sq_push <= 1'b0;
            if (m_arp_ready)
                m_arp_valid <= 1'b0;
            if (m_qp_ready)
                m_qp_valid <= 1'b0;

            // write: address and data together, one at a time
            if (s_axil_bvalid) begin
                if (s_axil_bready)
                    s_axil_bvalid <= 1'b0;
            end else if (s_axil_awvalid && s_axil_wvalid && !s_axil_awready) begin
                s_axil_awready <= 1'b1;
                s_axil_wready <= 1'b1;
                s_axil_bvalid <= 1'b1;
                if (s_axil_wstrb == 4'hF)
                    case (w_reg)
                        12'h00C: scratch <= s_axil_wdata;
                        12'h020: local_mac[31:0] <= s_axil_wdata;
                        12'h024: local_mac[47:32] <= s_axil_wdata[15:0];
                        12'h028: local_ip <= s_axil_wdata;
                        12'h02C: begin
                            m_arp_data <= s_axil_wdata;
                            m_arp_valid <= 1'b1;
                        end
                        12'h040: qp_lqpn <= s_axil_wdata[15:0];
                        12'h044: qp_rqpn <= s_axil_wdata[23:0];
                        12'h048: qp_lpsn <= s_axil_wdata[23:0];
                        12'h04C: qp_rpsn <= s_axil_wdata[23:0];
                        12'h050: qp_rip <= s_axil_wdata;
                        12'h054: qp_rport <= s_axil_wdata[15:0];
                        12'h058: qp_rkey <= s_axil_wdata;
                        12'h05C: begin
                            qp_mode <= s_axil_wdata[1:0];
                            m_qp_valid <= 1'b1;
                        end
                        12'h080: sq_ctrl <= s_axil_wdata & 32'h0000_3F01;
                        12'h084: sq_len <= s_axil_wdata & ~32'd3;
                        12'h088: sq_laddr[31:0] <= s_axil_wdata;
                        12'h08C: sq_laddr[47:32] <= s_axil_wdata[15:0];
                        12'h090: sq_raddr[31:0] <= s_axil_wdata;
                        12'h094: sq_raddr[47:32] <= s_axil_wdata[15:0];
                        // queued only when there is room: SQ_POST reads back
                        // the old value otherwise, and the same write repeated
                        // posts it later
                        12'h098: if (s_axil_wdata != sq_db && sq_push_ready) begin
                            sq_db <= s_axil_wdata;
                            sq_push <= sq_len != 0;
                        end
                        default: ;
                    endcase
            end

            // read
            if (s_axil_rvalid) begin
                if (s_axil_rready)
                    s_axil_rvalid <= 1'b0;
            end else if (s_axil_arready) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rdata <= reg_rdata;
            end else if (s_axil_arvalid) begin
                s_axil_arready <= 1'b1;
                r_addr <= s_axil_araddr;
            end
        end
    end
endmodule
