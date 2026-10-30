`timescale 1ns / 1ps

import roce_pkg::*;

// RoCE v2 engine: the rocev2 transport of this repository (HLS IP
// rocev2_ip: ICRC strip, IPv4, UDP, InfiniBand RC transport with
// retransmission) and around it
//   RX:  FIFO -> roce_ack_pacer -> rocev2
//   TX:  rocev2 -> roce_tx_trim -> icrc_core (appends the ICRC)
//   roce_flow:        send queue windows, completions
//   roce_payload:     payload commands / data, retransmission mirror
//   roce_retrans_mem: the retransmission buffer (QPs below 2^RT_QP_BITS)
// The streams are IPv4 packets (no Ethernet header), DATA_BITS wide (the
// width rocev2_ip was built at).
module roce_engine #(
    parameter integer DATA_BITS = 1024,
    parameter integer RT_QP_BITS = 3,
    parameter integer WR_WINDOW = 32,
    parameter integer RD_WINDOW = 32,
    parameter integer ACK_GAP_CYCLES = 20
) (
    input  logic          clk,
    input  logic          resetn,

    input  logic [31:0]   local_ip,             // first octet in bits 31:24

    // IPv4 RoCE packets from / to the IP layer
    input  logic          s_rx_tvalid,
    output logic          s_rx_tready,
    input  logic [DATA_BITS-1:0] s_rx_tdata,
    input  logic [DATA_BITS/8-1:0] s_rx_tkeep,
    input  logic          s_rx_tlast,

    output logic          m_tx_tvalid,
    input  logic          m_tx_tready,
    output logic [DATA_BITS-1:0] m_tx_tdata,
    output logic [DATA_BITS/8-1:0] m_tx_tkeep,
    output logic          m_tx_tlast,

    // QP setup
    input  logic          s_qp_valid,
    output logic          s_qp_ready,
    input  qp_ctx_hls_t   s_qp_data,
    input  logic          s_conn_valid,
    output logic          s_conn_ready,
    input  qp_conn_hls_t  s_conn_data,

    // send queue and completions
    input  logic          s_sq_valid,
    output logic          s_sq_ready,
    input  sq_req_t       s_sq_data,
    output logic          m_ack_valid,
    output ack_t          m_ack_data,

    // payload source (outgoing WRITEs, READ responses)
    output logic          m_rd_req_valid,
    input  logic          m_rd_req_ready,
    output mem_req_t      m_rd_req_data,
    input  logic          s_rd_tvalid,
    output logic          s_rd_tready,
    input  logic [DATA_BITS-1:0] s_rd_tdata,
    input  logic [DATA_BITS/8-1:0] s_rd_tkeep,
    input  logic          s_rd_tlast,

    // payload sink (incoming WRITEs, READ responses)
    output logic          m_wr_req_valid,
    input  logic          m_wr_req_ready,
    output mem_req_t      m_wr_req_data,
    output logic          m_wr_tvalid,
    input  logic          m_wr_tready,
    output logic [DATA_BITS-1:0] m_wr_tdata,
    output logic [DATA_BITS/8-1:0] m_wr_tkeep,
    output logic          m_wr_tlast,

    // statistics
    output logic [31:0]   stat_rx_pkts,         // packets into the transport
    output logic [31:0]   stat_tx_pkts,         // packets out of it (with ICRC)
    output logic [31:0]   stat_ibv_rx,
    output logic [31:0]   stat_ibv_tx,
    output logic [31:0]   stat_psn_drops,
    output logic [31:0]   stat_retrans,
    output logic [31:0]   stat_crc_drops,
    output logic [31:0]   stat_ack_held,
    output logic [31:0]   stat_trimmed,
    output logic [31:0]   stat_stray_acks
);
    // ------------------------------------------------------------ resets
    // one registered reset per block, replicated by synthesis
    (* max_fanout = 64 *) logic rst_hls_n, rst_rx_n, rst_tx_n, rst_flow_n, rst_pl_n, rst_rt_n;
    always_ff @(posedge clk) begin
        rst_hls_n <= resetn;
        rst_rx_n <= resetn;
        rst_tx_n <= resetn;
        rst_flow_n <= resetn;
        rst_pl_n <= resetn;
        rst_rt_n <= resetn;
    end

    // ------------------------------------------------------------ RX
    logic          f_tvalid, f_tready, f_tlast;
    logic [DATA_BITS-1:0] f_tdata;
    logic [DATA_BITS/8-1:0] f_tkeep;

    xpm_fifo_axis #(
        .CLOCKING_MODE("common_clock"),
        .FIFO_DEPTH(64),
        .FIFO_MEMORY_TYPE("auto"),
        .PACKET_FIFO("false"),
        .TDATA_WIDTH(DATA_BITS),
        .TDEST_WIDTH(1),
        .TID_WIDTH(1),
        .TUSER_WIDTH(1),
        .ECC_MODE("no_ecc"),
        .USE_ADV_FEATURES("0000")
    ) inst_rx_fifo (
        .s_aclk(clk), .s_aresetn(rst_rx_n), .m_aclk(clk),
        .s_axis_tvalid(s_rx_tvalid), .s_axis_tready(s_rx_tready),
        .s_axis_tdata(s_rx_tdata), .s_axis_tkeep(s_rx_tkeep), .s_axis_tlast(s_rx_tlast),
        .s_axis_tstrb(s_rx_tkeep), .s_axis_tdest(1'b0), .s_axis_tid(1'b0), .s_axis_tuser(1'b0),
        .m_axis_tvalid(f_tvalid), .m_axis_tready(f_tready),
        .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tlast(f_tlast),
        .m_axis_tstrb(), .m_axis_tdest(), .m_axis_tid(), .m_axis_tuser(),
        .prog_full_axis(), .wr_data_count_axis(), .almost_full_axis(),
        .prog_empty_axis(), .rd_data_count_axis(), .almost_empty_axis(),
        .injectsbiterr_axis(1'b0), .injectdbiterr_axis(1'b0), .sbiterr_axis(), .dbiterr_axis()
    );

    logic          r_tvalid, r_tready, r_tlast;
    logic [DATA_BITS-1:0] r_tdata;
    logic [DATA_BITS/8-1:0] r_tkeep;

    roce_ack_pacer #(.DATA_BITS(DATA_BITS), .GAP_CYCLES(ACK_GAP_CYCLES)) inst_pacer (
        .clk(clk), .resetn(rst_rx_n),
        .s_tvalid(f_tvalid), .s_tready(f_tready), .s_tdata(f_tdata), .s_tkeep(f_tkeep), .s_tlast(f_tlast),
        .m_tvalid(r_tvalid), .m_tready(r_tready), .m_tdata(r_tdata), .m_tkeep(r_tkeep), .m_tlast(r_tlast),
        .stat_held(stat_ack_held)
    );

    // ------------------------------------------------------------ transport
    logic          t_tvalid, t_tready, t_tlast;
    logic [DATA_BITS-1:0] t_tdata;
    logic [DATA_BITS/8-1:0] t_tkeep;

    logic          meta_valid, meta_ready;
    tx_meta_hls_t  meta_data;
    logic          am_valid, am_ready;
    logic [63:0]   am_data;
    logic          rdc_valid, rdc_ready, wrc_valid, wrc_ready;
    logic [143:0]  rdc_data, wrc_data;
    logic          pd_tvalid, pd_tready, pd_tlast;
    logic [DATA_BITS-1:0] pd_tdata;
    logic [DATA_BITS/8-1:0] pd_tkeep;

    logic [31:0] crc_drops, psn_drops, retrans, ibv_rx, ibv_tx;
    logic        crc_drops_vld, psn_drops_vld, retrans_vld, ibv_rx_vld, ibv_tx_vld;

    rocev2_ip inst_rocev2 (
        .ap_clk(clk), .ap_rst_n(rst_hls_n),
        .s_axis_rx_data_TVALID(r_tvalid), .s_axis_rx_data_TREADY(r_tready),
        .s_axis_rx_data_TDATA(r_tdata), .s_axis_rx_data_TKEEP(r_tkeep), .s_axis_rx_data_TSTRB(r_tkeep),
        .s_axis_rx_data_TLAST(r_tlast),
        .m_axis_tx_data_TVALID(t_tvalid), .m_axis_tx_data_TREADY(t_tready),
        .m_axis_tx_data_TDATA(t_tdata), .m_axis_tx_data_TKEEP(t_tkeep), .m_axis_tx_data_TSTRB(),
        .m_axis_tx_data_TLAST(t_tlast),
        .s_axis_sq_meta_TVALID(meta_valid), .s_axis_sq_meta_TREADY(meta_ready), .s_axis_sq_meta_TDATA(meta_data),
        .m_axis_rx_ack_meta_TVALID(am_valid), .m_axis_rx_ack_meta_TREADY(am_ready), .m_axis_rx_ack_meta_TDATA(am_data),
        .m_axis_mem_write_cmd_TVALID(wrc_valid), .m_axis_mem_write_cmd_TREADY(wrc_ready), .m_axis_mem_write_cmd_TDATA(wrc_data),
        .m_axis_mem_read_cmd_TVALID(rdc_valid), .m_axis_mem_read_cmd_TREADY(rdc_ready), .m_axis_mem_read_cmd_TDATA(rdc_data),
        .m_axis_mem_write_data_TVALID(m_wr_tvalid), .m_axis_mem_write_data_TREADY(m_wr_tready),
        .m_axis_mem_write_data_TDATA(m_wr_tdata), .m_axis_mem_write_data_TKEEP(m_wr_tkeep), .m_axis_mem_write_data_TSTRB(),
        .m_axis_mem_write_data_TLAST(m_wr_tlast),
        .s_axis_mem_read_data_TVALID(pd_tvalid), .s_axis_mem_read_data_TREADY(pd_tready),
        .s_axis_mem_read_data_TDATA(pd_tdata), .s_axis_mem_read_data_TKEEP(pd_tkeep), .s_axis_mem_read_data_TSTRB(pd_tkeep),
        .s_axis_mem_read_data_TLAST(pd_tlast),
        .s_axis_qp_interface_TVALID(s_qp_valid), .s_axis_qp_interface_TREADY(s_qp_ready), .s_axis_qp_interface_TDATA(s_qp_data),
        .s_axis_qp_conn_interface_TVALID(s_conn_valid), .s_axis_qp_conn_interface_TREADY(s_conn_ready),
        .s_axis_qp_conn_interface_TDATA(s_conn_data),
        .local_ip_address({4{bswap32(local_ip)}}),
        .m_axis_dbg_0_TVALID(), .m_axis_dbg_0_TREADY(1'b1), .m_axis_dbg_0_TDATA(),
        .m_axis_dbg_1_TVALID(), .m_axis_dbg_1_TREADY(1'b1), .m_axis_dbg_1_TDATA(),
        .m_axis_dbg_2_TVALID(), .m_axis_dbg_2_TREADY(1'b1), .m_axis_dbg_2_TDATA(),
        .regCrcDropPkgCount(crc_drops), .regCrcDropPkgCount_ap_vld(crc_drops_vld),
        .regInvalidPsnDropCount(psn_drops), .regInvalidPsnDropCount_ap_vld(psn_drops_vld),
        .regRetransCount(retrans), .regRetransCount_ap_vld(retrans_vld),
        .regIbvCountRx(ibv_rx), .regIbvCountRx_ap_vld(ibv_rx_vld),
        .regIbvCountTx(ibv_tx), .regIbvCountTx_ap_vld(ibv_tx_vld)
    );

    // the HLS counters are valid with their ap_vld
    always_ff @(posedge clk) begin
        if (!rst_hls_n) begin
            stat_crc_drops <= 0;
            stat_psn_drops <= 0;
            stat_retrans <= 0;
            stat_ibv_rx <= 0;
            stat_ibv_tx <= 0;
        end else begin
            if (crc_drops_vld) stat_crc_drops <= crc_drops;
            if (psn_drops_vld) stat_psn_drops <= psn_drops;
            if (retrans_vld) stat_retrans <= retrans;
            if (ibv_rx_vld) stat_ibv_rx <= ibv_rx;
            if (ibv_tx_vld) stat_ibv_tx <= ibv_tx;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_rx_n) begin
            stat_rx_pkts <= 0;
            stat_tx_pkts <= 0;
        end else begin
            if (r_tvalid && r_tready && r_tlast)
                stat_rx_pkts <= stat_rx_pkts + 1;
            if (m_tx_tvalid && m_tx_tready && m_tx_tlast)
                stat_tx_pkts <= stat_tx_pkts + 1;
        end
    end

    // ------------------------------------------------------------ TX: trim, ICRC
    logic          c_tvalid, c_tready, c_tlast;
    logic [DATA_BITS-1:0] c_tdata;
    logic [DATA_BITS/8-1:0] c_tkeep;

    roce_tx_trim #(.DATA_BITS(DATA_BITS)) inst_trim (
        .clk(clk), .resetn(rst_tx_n),
        .s_tvalid(t_tvalid), .s_tready(t_tready), .s_tdata(t_tdata), .s_tkeep(t_tkeep), .s_tlast(t_tlast),
        .m_tvalid(c_tvalid), .m_tready(c_tready), .m_tdata(c_tdata), .m_tkeep(c_tkeep), .m_tlast(c_tlast),
        .stat_trimmed(stat_trimmed)
    );

    icrc_core #(.DATA_BITS(DATA_BITS)) inst_icrc (
        .aclk(clk), .aresetn(rst_tx_n),
        .s_tvalid(c_tvalid), .s_tready(c_tready), .s_tdata(c_tdata), .s_tkeep(c_tkeep), .s_tlast(c_tlast),
        .m_tvalid(m_tx_tvalid), .m_tready(m_tx_tready), .m_tdata(m_tx_tdata), .m_tkeep(m_tx_tkeep), .m_tlast(m_tx_tlast)
    );

    // ------------------------------------------------------------ send queue, completions
    roce_flow #(
        .QP_BITS(6), .WR_WINDOW(WR_WINDOW), .RD_WINDOW(RD_WINDOW)
    ) inst_flow (
        .clk(clk), .resetn(rst_flow_n),
        .s_sq_valid(s_sq_valid), .s_sq_ready(s_sq_ready), .s_sq_data(s_sq_data),
        .m_meta_valid(meta_valid), .m_meta_ready(meta_ready), .m_meta_data(meta_data),
        .s_ack_valid(am_valid), .s_ack_ready(am_ready), .s_ack_data(ack_meta_hls_t'(am_data)),
        .m_ack_valid(m_ack_valid), .m_ack_data(m_ack_data),
        .stat_stray_acks(stat_stray_acks)
    );

    // ------------------------------------------------------------ payload
    logic          rtw_cmd_valid, rtw_cmd_ready, rtw_tvalid, rtw_tready, rtw_tlast;
    logic [95:0]   rtw_cmd_data, rtr_cmd_data;
    logic [DATA_BITS-1:0] rtw_tdata, rtr_tdata;
    logic          rtr_cmd_valid, rtr_cmd_ready, rtr_tvalid, rtr_tready, rtr_tlast;
    logic [DATA_BITS/8-1:0] rtr_tkeep;

    roce_payload #(.DATA_BITS(DATA_BITS), .RT_QP_BITS(RT_QP_BITS)) inst_payload (
        .clk(clk), .resetn(rst_pl_n),
        .s_rdcmd_valid(rdc_valid), .s_rdcmd_ready(rdc_ready), .s_rdcmd_data(mem_cmd_hls_t'(rdc_data)),
        .m_tvalid(pd_tvalid), .m_tready(pd_tready), .m_tdata(pd_tdata), .m_tkeep(pd_tkeep), .m_tlast(pd_tlast),
        .m_src_valid(m_rd_req_valid), .m_src_ready(m_rd_req_ready), .m_src_data(m_rd_req_data),
        .s_src_tvalid(s_rd_tvalid), .s_src_tready(s_rd_tready), .s_src_tdata(s_rd_tdata),
        .s_src_tkeep(s_rd_tkeep), .s_src_tlast(s_rd_tlast),
        .m_rtw_cmd_valid(rtw_cmd_valid), .m_rtw_cmd_ready(rtw_cmd_ready), .m_rtw_cmd_data(rtw_cmd_data),
        .m_rtw_tvalid(rtw_tvalid), .m_rtw_tready(rtw_tready), .m_rtw_tdata(rtw_tdata), .m_rtw_tlast(rtw_tlast),
        .m_rtr_cmd_valid(rtr_cmd_valid), .m_rtr_cmd_ready(rtr_cmd_ready), .m_rtr_cmd_data(rtr_cmd_data),
        .s_rtr_tvalid(rtr_tvalid), .s_rtr_tready(rtr_tready), .s_rtr_tdata(rtr_tdata),
        .s_rtr_tkeep(rtr_tkeep), .s_rtr_tlast(rtr_tlast),
        .s_wrcmd_valid(wrc_valid), .s_wrcmd_ready(wrc_ready), .s_wrcmd_data(mem_cmd_hls_t'(wrc_data)),
        .m_snk_valid(m_wr_req_valid), .m_snk_ready(m_wr_req_ready), .m_snk_data(m_wr_req_data)
    );

    roce_retrans_mem #(.DATA_BITS(DATA_BITS), .QP_BITS(RT_QP_BITS)) inst_retrans (
        .clk(clk), .resetn(rst_rt_n),
        .s_wr_cmd_valid(rtw_cmd_valid), .s_wr_cmd_ready(rtw_cmd_ready), .s_wr_cmd_data(rtw_cmd_data),
        .s_wr_tdata(rtw_tdata), .s_wr_tlast(rtw_tlast), .s_wr_tvalid(rtw_tvalid), .s_wr_tready(rtw_tready),
        .s_rd_cmd_valid(rtr_cmd_valid), .s_rd_cmd_ready(rtr_cmd_ready), .s_rd_cmd_data(rtr_cmd_data),
        .m_rd_tdata(rtr_tdata), .m_rd_tkeep(rtr_tkeep), .m_rd_tlast(rtr_tlast),
        .m_rd_tvalid(rtr_tvalid), .m_rd_tready(rtr_tready)
    );

`ifdef ROCE_TRACE
    // first beats into and out of the transport: BTH opcode, PSN, IP length
    logic r_first = 1, c_first = 1;
    logic [15:0] tr_cnt = 0;
    always_ff @(posedge clk) begin
        tr_cnt <= tr_cnt + 1;
        if (tr_cnt == 0)
            $display("%t %m: state in v/r %b%b fifo v/r %b%b rocev2 rx v/r %b%b tx v/r %b%b",
                $time, s_rx_tvalid, s_rx_tready, f_tvalid, f_tready, r_tvalid, r_tready, t_tvalid, t_tready);
        if (r_tvalid && r_tready) begin
            r_first <= r_tlast;
            if (r_first)
                $display("%t %m: rx op %02x psn %06x iplen %0d", $time, r_tdata[8*28 +: 8],
                    {r_tdata[8*37 +: 8], r_tdata[8*38 +: 8], r_tdata[8*39 +: 8]}, {r_tdata[8*2 +: 8], r_tdata[8*3 +: 8]});
        end
        if (c_tvalid && c_tready) begin
            c_first <= c_tlast;
            if (c_first)
                $display("%t %m: tx op %02x psn %06x iplen %0d", $time, c_tdata[8*28 +: 8],
                    {c_tdata[8*37 +: 8], c_tdata[8*38 +: 8], c_tdata[8*39 +: 8]}, {c_tdata[8*2 +: 8], c_tdata[8*3 +: 8]});
        end
    end
`endif
endmodule
