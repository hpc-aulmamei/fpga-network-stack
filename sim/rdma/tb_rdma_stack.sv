`timescale 1ns / 1ps

// Two RDMA stack IPs (packaged sources, top `RDMA_TOP, DATA_BITS `DATA_BITS)
// back to back over a link model at LINE_GBPS, with payload models that
// check every byte.
//
// Payload convention: the source of either node serves pat(a) at address a;
// WRITEs use a local address = remote address + OFF and READs a remote
// address = local address + OFF, so every byte that reaches a sink at address
// x must be pat(x + OFF).
//
// Plusargs: +N=<4 KiB requests per throughput test> +MIXED=<messages>
//           +DROP=<drop 1 in N RoCE frames at random, 0 = none> +LINE_GBPS=<link rate>
//           +STALL=<1: random gaps in the payload streams>
//           +REG_POSTS=<1 in N mixed messages posted through the registers, 0 = none>
// (run_tb.sh turns +SEED=<n> into xsim -sv_seed <n>)
module tb_rdma_stack;
    localparam int DATA_BITS = `DATA_BITS;
    localparam int BYTES = DATA_BITS / 8;
    localparam real CLK_NS = 4.0;
    localparam longint OFF = 64'h0000_1000_0000;

    int n_tput = 200, n_mixed = 300, drop = 0, line_gbps = (DATA_BITS == 1024) ? 200 : 100;
    int stall = 0;
    // mixed test: +MIX_OPS=1 WRITEs only, 2 READs only; +MIX_DIR=1 node A posts only;
    // +MIX_QP=<n> that QP only; +MIX_ALIGN=<bytes> lengths and addresses multiples of it
    int mix_ops = 0, mix_dir = 0, mix_qp = 0, mix_align = 4, reg_posts = 8;
    logic [31:0] st_a [16], st_b [16], rv;

    logic clk = 1'b0;
    logic resetn = 1'b0;
    always #(CLK_NS / 2) clk = !clk;

    // ------------------------------------------------------------ nodes
    `define RDMA_NODE_WIRES(n) \
        logic                 n``_rx_tvalid, n``_rx_tready, n``_rx_tlast, n``_tx_tvalid, n``_tx_tready, n``_tx_tlast; \
        logic [DATA_BITS-1:0] n``_rx_tdata, n``_tx_tdata; \
        logic [BYTES-1:0]     n``_rx_tkeep, n``_tx_tkeep; \
        logic                 n``_sq_tvalid, n``_sq_tready, n``_cq_tvalid; \
        logic [11:0]          n``_awaddr, n``_araddr; \
        logic                 n``_awvalid, n``_awready, n``_wvalid, n``_wready, n``_bvalid, n``_bready; \
        logic                 n``_arvalid, n``_arready, n``_rvalid, n``_rready; \
        logic [31:0]          n``_wdata, n``_rdata; \
        logic [3:0]           n``_wstrb; \
        logic [191:0]         n``_sq_tdata; \
        logic [31:0]          n``_cq_tdata; \
        logic                 n``_rdq_tvalid, n``_rdq_tready, n``_wrq_tvalid, n``_wrq_tready; \
        logic [127:0]         n``_rdq_tdata, n``_wrq_tdata; \
        logic                 n``_rd_tvalid, n``_rd_tready, n``_rd_tlast, n``_wr_tvalid, n``_wr_tready, n``_wr_tlast; \
        logic [DATA_BITS-1:0] n``_rd_tdata, n``_wr_tdata; \
        logic [BYTES-1:0]     n``_rd_tkeep, n``_wr_tkeep;

    `RDMA_NODE_WIRES(a)
    `RDMA_NODE_WIRES(b)

    `define RDMA_NODE(n) \
        `RDMA_TOP #(.DATA_BITS(DATA_BITS)) dut_``n ( \
            .aclk(clk), .aresetn(resetn), \
            .s_axil_awaddr(n``_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(n``_awvalid), .s_axil_awready(n``_awready), \
            .s_axil_wdata(n``_wdata), .s_axil_wstrb(n``_wstrb), .s_axil_wvalid(n``_wvalid), .s_axil_wready(n``_wready), \
            .s_axil_bresp(), .s_axil_bvalid(n``_bvalid), .s_axil_bready(n``_bready), \
            .s_axil_araddr(n``_araddr), .s_axil_arprot(3'd0), .s_axil_arvalid(n``_arvalid), .s_axil_arready(n``_arready), \
            .s_axil_rdata(n``_rdata), .s_axil_rresp(), .s_axil_rvalid(n``_rvalid), .s_axil_rready(n``_rready), \
            .s_axis_rx_tvalid(n``_rx_tvalid), .s_axis_rx_tready(n``_rx_tready), .s_axis_rx_tdata(n``_rx_tdata), \
            .s_axis_rx_tkeep(n``_rx_tkeep), .s_axis_rx_tlast(n``_rx_tlast), .s_axis_rx_tuser(1'b0), \
            .m_axis_tx_tvalid(n``_tx_tvalid), .m_axis_tx_tready(n``_tx_tready), .m_axis_tx_tdata(n``_tx_tdata), \
            .m_axis_tx_tkeep(n``_tx_tkeep), .m_axis_tx_tlast(n``_tx_tlast), \
            .s_axis_sq_tvalid(n``_sq_tvalid), .s_axis_sq_tready(n``_sq_tready), .s_axis_sq_tdata(n``_sq_tdata), \
            .m_axis_cq_tvalid(n``_cq_tvalid), .m_axis_cq_tdata(n``_cq_tdata), \
            .m_axis_rd_req_tvalid(n``_rdq_tvalid), .m_axis_rd_req_tready(n``_rdq_tready), .m_axis_rd_req_tdata(n``_rdq_tdata), \
            .s_axis_rd_tvalid(n``_rd_tvalid), .s_axis_rd_tready(n``_rd_tready), .s_axis_rd_tdata(n``_rd_tdata), \
            .s_axis_rd_tkeep(n``_rd_tkeep), .s_axis_rd_tlast(n``_rd_tlast), \
            .m_axis_wr_req_tvalid(n``_wrq_tvalid), .m_axis_wr_req_tready(n``_wrq_tready), .m_axis_wr_req_tdata(n``_wrq_tdata), \
            .m_axis_wr_tvalid(n``_wr_tvalid), .m_axis_wr_tready(n``_wr_tready), .m_axis_wr_tdata(n``_wr_tdata), \
            .m_axis_wr_tkeep(n``_wr_tkeep), .m_axis_wr_tlast(n``_wr_tlast) \
        ); \
        rdma_tb_axil axil_``n ( \
            .clk(clk), .awaddr(n``_awaddr), .awvalid(n``_awvalid), .awready(n``_awready), \
            .wdata(n``_wdata), .wstrb(n``_wstrb), .wvalid(n``_wvalid), .wready(n``_wready), \
            .bvalid(n``_bvalid), .bready(n``_bready), .araddr(n``_araddr), .arvalid(n``_arvalid), \
            .arready(n``_arready), .rdata(n``_rdata), .rvalid(n``_rvalid), .rready(n``_rready) \
        ); \
        rdma_tb_payload #(.DATA_BITS(DATA_BITS), .OFF(OFF)) mdl_``n ( \
            .clk(clk), .resetn(resetn), \
            .sq_tvalid(n``_sq_tvalid), .sq_tready(n``_sq_tready), .sq_tdata(n``_sq_tdata), \
            .cq_tvalid(n``_cq_tvalid), .cq_tdata(n``_cq_tdata), \
            .rdq_tvalid(n``_rdq_tvalid), .rdq_tready(n``_rdq_tready), .rdq_tdata(n``_rdq_tdata), \
            .rd_tvalid(n``_rd_tvalid), .rd_tready(n``_rd_tready), .rd_tdata(n``_rd_tdata), \
            .rd_tkeep(n``_rd_tkeep), .rd_tlast(n``_rd_tlast), \
            .wrq_tvalid(n``_wrq_tvalid), .wrq_tready(n``_wrq_tready), .wrq_tdata(n``_wrq_tdata), \
            .wr_tvalid(n``_wr_tvalid), .wr_tready(n``_wr_tready), .wr_tdata(n``_wr_tdata), \
            .wr_tkeep(n``_wr_tkeep), .wr_tlast(n``_wr_tlast) \
        );

    `RDMA_NODE(a)
    `RDMA_NODE(b)

    rdma_tb_link #(.DATA_BITS(DATA_BITS), .CLK_NS(CLK_NS)) link_ab (
        .clk(clk), .resetn(resetn), .line_gbps(line_gbps), .drop_every(drop),
        .s_tvalid(a_tx_tvalid), .s_tready(a_tx_tready), .s_tdata(a_tx_tdata), .s_tkeep(a_tx_tkeep), .s_tlast(a_tx_tlast),
        .m_tvalid(b_rx_tvalid), .m_tready(b_rx_tready), .m_tdata(b_rx_tdata), .m_tkeep(b_rx_tkeep), .m_tlast(b_rx_tlast)
    );
    rdma_tb_link #(.DATA_BITS(DATA_BITS), .CLK_NS(CLK_NS)) link_ba (
        .clk(clk), .resetn(resetn), .line_gbps(line_gbps), .drop_every(drop),
        .s_tvalid(b_tx_tvalid), .s_tready(b_tx_tready), .s_tdata(b_tx_tdata), .s_tkeep(b_tx_tkeep), .s_tlast(b_tx_tlast),
        .m_tvalid(a_rx_tvalid), .m_tready(a_rx_tready), .m_tdata(a_rx_tdata), .m_tkeep(a_rx_tkeep), .m_tlast(a_rx_tlast)
    );

    // ------------------------------------------------------------ test
    int fails = 0;
    longint cyc = 0;
    int qps[3] = '{1, 2, 12};
    always @(posedge clk) cyc <= cyc + 1;

    // ------------------------------------------------------------ registers
    task automatic wr(input bit node_b, input logic [11:0] a, input logic [31:0] d);
        if (node_b) axil_b.write(a, d); else axil_a.write(a, d);
    endtask

    task automatic rd(input bit node_b, input logic [11:0] a, output logic [31:0] d);
        if (node_b) axil_b.read(a, d); else axil_a.read(a, d);
    endtask

    task automatic stat(input bit node_b, input int i, output logic [31:0] d);
        rd(node_b, 12'h200 + 4 * i, d);
    endtask

    task automatic set_addr(input bit node_b, input logic [47:0] mac, input logic [31:0] ip);
        wr(node_b, 12'h020, mac[31:0]);
        wr(node_b, 12'h024, {16'd0, mac[47:32]});
        wr(node_b, 12'h028, ip);
    endtask

    task automatic connect(input bit node_b, input int lqpn, input int rqpn, input int lpsn, input int rpsn,
                           input logic [31:0] rip);
        wr(node_b, 12'h040, lqpn);
        wr(node_b, 12'h044, rqpn);
        wr(node_b, 12'h048, lpsn);
        wr(node_b, 12'h04C, rpsn);
        wr(node_b, 12'h050, rip);
        wr(node_b, 12'h054, 0);
        wr(node_b, 12'h058, 0);
        wr(node_b, 12'h05C, 0);
    endtask

    // a message through the register send queue: SQ_POST takes a new value
    // only when the queue has room, so write and read back until it sticks
    task automatic reg_post(input bit node_b, input bit read, input int qpn, input longint laddr,
                            input longint raddr, input int len);
        logic [31:0] db, back;
        wr(node_b, 12'h080, {18'd0, 6'(qpn), 7'd0, read});
        wr(node_b, 12'h084, len);
        wr(node_b, 12'h088, laddr[31:0]);
        wr(node_b, 12'h08C, laddr[47:32]);
        wr(node_b, 12'h090, raddr[31:0]);
        wr(node_b, 12'h094, raddr[47:32]);
        if (node_b) mdl_b.count_post(len); else mdl_a.count_post(len);
        rd(node_b, 12'h098, db);
        db++;
        do begin
            wr(node_b, 12'h098, db);
            rd(node_b, 12'h098, back);
        end while (back != db);
    endtask

    // all posted requests completed on both nodes
    task automatic wait_done(input string what, input longint timeout_cycles);
        longint t0 = cyc;
        while (!(mdl_a.idle() && mdl_b.idle())) begin
            @(posedge clk);
            if ((cyc - t0) % 100_000 == 0) begin
                $display("%s: cycle %0d, a %0d of %0d requests completed, b %0d of %0d; a->b %0d frames, b->a %0d",
                    what, cyc, mdl_a.done_reqs, mdl_a.posted_reqs, mdl_b.done_reqs, mdl_b.posted_reqs,
                    link_ab.frames, link_ba.frames);
                $display("  valid/ready  a: sq %b%b rdq %b%b rd %b%b wrq %b%b wr %b%b tx %b%b rx %b%b  b: sq %b%b rdq %b%b rd %b%b wrq %b%b wr %b%b tx %b%b rx %b%b",
                    a_sq_tvalid, a_sq_tready, a_rdq_tvalid, a_rdq_tready, a_rd_tvalid, a_rd_tready,
                    a_wrq_tvalid, a_wrq_tready, a_wr_tvalid, a_wr_tready, a_tx_tvalid, a_tx_tready, a_rx_tvalid, a_rx_tready,
                    b_sq_tvalid, b_sq_tready, b_rdq_tvalid, b_rdq_tready, b_rd_tvalid, b_rd_tready,
                    b_wrq_tvalid, b_wrq_tready, b_wr_tvalid, b_wr_tready, b_tx_tvalid, b_tx_tready, b_rx_tvalid, b_rx_tready);
                $display("  models a: sq queue %0d, source queue %0d busy %0d, sink queue %0d busy %0d; b: sq queue %0d, source queue %0d busy %0d, sink queue %0d busy %0d",
                    mdl_a.sq_q.size(), mdl_a.src_a.size(), mdl_a.s_busy, mdl_a.snk_a.size(), mdl_a.w_busy,
                    mdl_b.sq_q.size(), mdl_b.src_a.size(), mdl_b.s_busy, mdl_b.snk_a.size(), mdl_b.w_busy);
                $display("  b sq head: op %0d qp %0d len %0d", b_sq_tdata[0], b_sq_tdata[13:8], b_sq_tdata[63:32]);
                $display("  a source: addr %h left %0d, next %p / %p; rdq %h", mdl_a.s_addr, mdl_a.s_left, mdl_a.src_a, mdl_a.src_n, a_rdq_tdata);
                $display("  b source: addr %h left %0d, next %p / %p; rdq %h", mdl_b.s_addr, mdl_b.s_left, mdl_b.src_a, mdl_b.src_n, b_rdq_tdata);
                $display("  a payload: c v/r %b%b retrans %b mirror %b ord v %b data %b, o_ready %b rtw ready %b, src_tready %b, rtr v %b, rdc v/r %b%b meta v/r %b%b",
                    dut_a.inst_stack.inst_engine.inst_payload.c_valid, dut_a.inst_stack.inst_engine.inst_payload.c_ready,
                    dut_a.inst_stack.inst_engine.inst_payload.c_retrans, dut_a.inst_stack.inst_engine.inst_payload.c_mirror,
                    dut_a.inst_stack.inst_engine.inst_payload.ord_valid, dut_a.inst_stack.inst_engine.inst_payload.ord,
                    dut_a.inst_stack.inst_engine.inst_payload.o_ready, dut_a.inst_stack.inst_engine.inst_payload.m_rtw_tready,
                    dut_a.inst_stack.inst_engine.inst_payload.s_src_tready, dut_a.inst_stack.inst_engine.inst_payload.s_rtr_tvalid,
                    dut_a.inst_stack.inst_engine.rdc_valid, dut_a.inst_stack.inst_engine.rdc_ready,
                    dut_a.inst_stack.inst_engine.meta_valid, dut_a.inst_stack.inst_engine.meta_ready);
                $display("  a engine: pd v/r %b%b t v/r %b%b wrc v/r %b%b am v/r %b%b",
                    dut_a.inst_stack.inst_engine.pd_tvalid, dut_a.inst_stack.inst_engine.pd_tready,
                    dut_a.inst_stack.inst_engine.t_tvalid, dut_a.inst_stack.inst_engine.t_tready,
                    dut_a.inst_stack.inst_engine.wrc_valid, dut_a.inst_stack.inst_engine.wrc_ready,
                    dut_a.inst_stack.inst_engine.am_valid, dut_a.inst_stack.inst_engine.am_ready);
            end
            if (cyc - t0 > timeout_cycles) begin
                $display("FAIL %s: timeout, a: %0d of %0d requests completed, b: %0d of %0d", what,
                    mdl_a.done_reqs, mdl_a.posted_reqs, mdl_b.done_reqs, mdl_b.posted_reqs);
                fails++;
                return;
            end
        end
    endtask

    // Gb/s of payload over the cycles since t0
    function automatic real gbps(input longint bytes, input longint t0);
        return bytes * 8.0 / ((cyc - t0) * CLK_NS);
    endfunction

    task automatic tput(input string what, input bit read, input int n);
        longint t0, b0;
        t0 = cyc;
        b0 = mdl_a.sink_bytes + mdl_b.sink_bytes;
        for (int i = 0; i < n; i++)
            if (read)
                mdl_a.post(1, 1, 64'h10_0000 + i * 4096, 64'h10_0000 + i * 4096 + OFF, 4096);
            else
                mdl_a.post(0, 1, 64'h20_0000 + i * 4096 + OFF, 64'h20_0000 + i * 4096, 4096);
        wait_done(what, 2_000_000);
        $display("%s: %0d x 4 KiB in %0d cycles = %.1f Gb/s", what, n, cyc - t0,
            gbps(mdl_a.sink_bytes + mdl_b.sink_bytes - b0, t0));
    endtask

    initial begin
        void'($value$plusargs("N=%d", n_tput));
        void'($value$plusargs("MIXED=%d", n_mixed));
        void'($value$plusargs("DROP=%d", drop));
        void'($value$plusargs("LINE_GBPS=%d", line_gbps));
        void'($value$plusargs("STALL=%d", stall));
        void'($value$plusargs("MIX_OPS=%d", mix_ops));
        void'($value$plusargs("MIX_DIR=%d", mix_dir));
        void'($value$plusargs("MIX_QP=%d", mix_qp));
        void'($value$plusargs("MIX_ALIGN=%d", mix_align));
        void'($value$plusargs("REG_POSTS=%d", reg_posts));
        mdl_a.stall = stall;
        mdl_b.stall = stall;
        $display("tb_rdma_stack: %0d bits, link %0d Gb/s, drop every %0d, stall %0d",
            DATA_BITS, line_gbps, drop, stall);

        repeat (20) @(posedge clk);
        resetn = 1'b1;
        repeat (20) @(posedge clk);

        rd(0, 12'h000, rv);
        if (rv != 32'h5244_4D41) begin
            $display("FAIL: ID %h", rv);
            fails++;
        end
        rd(0, 12'h008, rv);
        $display("config: %0d bits, %0d retransmission QP bits, windows %0d / %0d",
            rv[11:0], rv[15:12], rv[23:16], rv[31:24]);
        set_addr(0, 48'h02_00_00_00_00_0a, 32'h0a_00_00_01);
        set_addr(1, 48'h02_00_00_00_00_0b, 32'h0a_00_00_02);
        repeat (100) @(posedge clk);

        // resolve the peers first: a packet to an unresolved address is
        // dropped and only sent again by the retransmission timer
        wr(0, 12'h02C, 32'h0a_00_00_02);
        wr(1, 12'h02C, 32'h0a_00_00_01);
        repeat (2000) @(posedge clk);
        stat(0, 2, st_a[2]);
        stat(1, 2, st_b[2]);
        if (st_a[2] == 0 || st_b[2] == 0) begin
            $display("FAIL: ARP: a received %0d, b %0d ARP frames", st_a[2], st_b[2]);
            fails++;
        end

        // QPs 1 and 2 retransmit from the on-chip buffer, 12 from the source
        foreach (qps[i]) begin
            connect(0, qps[i], qps[i], 24'h000100 + qps[i], 24'h000300 + qps[i], 32'h0a_00_00_02);
            connect(1, qps[i], qps[i], 24'h000300 + qps[i], 24'h000100 + qps[i], 32'h0a_00_00_01);
        end
        repeat (20) @(posedge clk);

        // one small WRITE through the register send queue
        reg_post(0, 0, 1, 64'h1000 + OFF, 64'h1000, 64);
        wait_done("single WRITE", 200_000);
        $display("single WRITE: done at cycle %0d", cyc);

        tput("WRITE A->B", 0, n_tput);
        $display("link a->b: %0d frames, %0d bytes by cycle %0d", link_ab.frames, link_ab.bytes, cyc);
        tput("READ A<-B", 1, n_tput);

        // random messages, both directions, all three QPs, 4 B .. 20 KiB
        begin
            longint t0 = cyc, b0 = mdl_a.sink_bytes + mdl_b.sink_bytes;
            for (int i = 0; i < n_mixed; i++) begin
                automatic bit read = mix_ops == 1 ? 0 : mix_ops == 2 ? 1 : $urandom_range(1);
                automatic int q = mix_qp != 0 ? mix_qp : $urandom_range(2) == 0 ? 1 : $urandom_range(1) ? 2 : 12;
                automatic int len = mix_align * $urandom_range(1, 20480 / mix_align);
                automatic longint la = 64'h4000_0000 + mix_align * $urandom_range(0, (1 << 22) / mix_align);
                automatic longint ra = read ? la + OFF : la - OFF;
                automatic bit on_b = !(mix_dir == 1 || $urandom_range(1));
                if (reg_posts != 0 && $urandom_range(reg_posts - 1) == 0)
                    reg_post(on_b, read, q, la, ra, len);
                else if (on_b)
                    mdl_b.post(read, q, la, ra, len);
                else
                    mdl_a.post(read, q, la, ra, len);
            end
            wait_done("mixed", 20_000_000);
            $display("mixed: %0d messages in %0d cycles = %.1f Gb/s", n_mixed, cyc - t0,
                gbps(mdl_a.sink_bytes + mdl_b.sink_bytes - b0, t0));
        end

        repeat (200) @(posedge clk);
        foreach (st_a[i]) begin
            stat(0, i, st_a[i]);
            stat(1, i, st_b[i]);
            $display("stat %2d: a %0d b %0d", i, st_a[i], st_b[i]);
        end
        // completion counters: one per request, messages flagged
        rd(0, 12'h108, rv);
        if (rv != mdl_a.msgs_done) begin
            $display("FAIL: CQ_MSGS of a %0d, model %0d", rv, mdl_a.msgs_done);
            fails++;
        end
        rd(1, 12'h100, rv);
        if (rv != mdl_b.done_reqs) begin
            $display("FAIL: CQ_COUNT of b %0d, model %0d", rv, mdl_b.done_reqs);
            fails++;
        end
        $display("link: a->b %0d frames %0d bytes %0d dropped, b->a %0d frames %0d bytes %0d dropped, %0d cycles",
            link_ab.frames, link_ab.bytes, link_ab.dropped, link_ba.frames, link_ba.bytes, link_ba.dropped, cyc);
        fails += mdl_a.errors + mdl_b.errors;
        if (mdl_a.msgs_done != mdl_a.msgs_posted || mdl_b.msgs_done != mdl_b.msgs_posted) begin
            $display("FAIL: messages completed a %0d of %0d, b %0d of %0d",
                mdl_a.msgs_done, mdl_a.msgs_posted, mdl_b.msgs_done, mdl_b.msgs_posted);
            fails++;
        end
        if (drop == 0 && (st_a[9] != 0 || st_b[9] != 0 || st_a[8] != 0 || st_b[8] != 0)) begin
            $display("FAIL: retransmissions or PSN drops without loss");
            fails++;
        end
        if (st_a[13] != 0 || st_b[13] != 0) begin
            $display("FAIL: stray completions");
            fails++;
        end
        $display("%s: tb_rdma_stack %0d bits drop %0d (%0d failures)", fails ? "FAIL" : "PASS", DATA_BITS, drop, fails);
        $finish;
    end
endmodule

// Link: passes frames at line_gbps (frame bytes + 24 for FCS, preamble and
// gap), dropping RoCE frames at random with probability 1/drop_every (a fixed
// period lines the drops of both directions up, e.g. every NAK of a loss).
module rdma_tb_link #(
    parameter int DATA_BITS = 1024,
    parameter real CLK_NS = 4.0
) (
    input  logic                   clk,
    input  logic                   resetn,
    input  int                     line_gbps,
    input  int                     drop_every,
    input  logic                   s_tvalid,
    output logic                   s_tready,
    input  logic [DATA_BITS-1:0]   s_tdata,
    input  logic [DATA_BITS/8-1:0] s_tkeep,
    input  logic                   s_tlast,
    output logic                   m_tvalid,
    input  logic                   m_tready,
    output logic [DATA_BITS-1:0]   m_tdata,
    output logic [DATA_BITS/8-1:0] m_tkeep,
    output logic                   m_tlast
);
    localparam int BYTES = DATA_BITS / 8;
    real credit = 0;
    logic has_credit = 1'b0;            // registered, so s_tready is stable at the clock edge
    int frames = 0, dropped = 0;
    longint bytes = 0;
    bit first = 1, dropping = 0;

    function automatic int nbytes(input logic [DATA_BITS/8-1:0] k);
        int n = 0;
        for (int i = 0; i < DATA_BITS / 8; i++)
            n += (k[i] === 1'b1);
        return n;
    endfunction

    function automatic bit is_roce(input logic [DATA_BITS-1:0] d);
        return d[8*12 +: 8] == 8'h08 && d[8*13 +: 8] == 8'h00 && d[8*23 +: 8] == 8'h11 &&
               d[8*36 +: 8] == 8'h12 && d[8*37 +: 8] == 8'hB7;
    endfunction

    assign s_tready = (!m_tvalid || m_tready) && has_credit;

    always @(posedge clk) begin
        if (!resetn) begin
            m_tvalid <= 1'b0;
            credit = 0;
            has_credit <= 1'b0;
        end else begin
            if (credit < 2 * BYTES)
                credit += line_gbps * CLK_NS / 8.0;
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;
            if (s_tvalid && s_tready) begin
                automatic bit drop_this = first ? (drop_every > 0 && is_roce(s_tdata) && $urandom_range(drop_every - 1) == 0) : dropping;
                credit -= nbytes(s_tkeep) + (s_tlast ? 24 : 0);
                bytes += nbytes(s_tkeep);
                if (first) begin
                    frames++;
                    if (drop_this)
                        dropped++;
                end
                dropping = drop_this;
                first = s_tlast;
                m_tvalid <= !drop_this;
                m_tdata <= s_tdata;
                m_tkeep <= s_tkeep;
                m_tlast <= s_tlast;
            end
            has_credit <= credit > 0;
        end
    end
endmodule

// Payload source / sink, QP setup, send queue and completions of one node.
module rdma_tb_payload #(
    parameter int DATA_BITS = 1024,
    parameter longint OFF = 0
) (
    input  logic                   clk,
    input  logic                   resetn,
    output logic                   sq_tvalid,
    input  logic                   sq_tready,
    output logic [191:0]           sq_tdata,
    input  logic                   cq_tvalid,
    input  logic [31:0]            cq_tdata,
    input  logic                   rdq_tvalid,
    output logic                   rdq_tready,
    input  logic [127:0]           rdq_tdata,
    output logic                   rd_tvalid,
    input  logic                   rd_tready,
    output logic [DATA_BITS-1:0]   rd_tdata,
    output logic [DATA_BITS/8-1:0] rd_tkeep,
    output logic                   rd_tlast,
    input  logic                   wrq_tvalid,
    output logic                   wrq_tready,
    input  logic [127:0]           wrq_tdata,
    input  logic                   wr_tvalid,
    output logic                   wr_tready,
    input  logic [DATA_BITS-1:0]   wr_tdata,
    input  logic [DATA_BITS/8-1:0] wr_tkeep,
    input  logic                   wr_tlast
);
    localparam int BYTES = DATA_BITS / 8;

    function automatic logic [7:0] pat(input longint a);
        return 8'(a ^ (a >> 8) ^ (a >> 16) ^ (a >> 24) ^ (a >> 32)) ^ 8'h5a;
    endfunction

    int stall = 0;
    int errors = 0;
    longint sink_bytes = 0;
    int posted_reqs = 0, done_reqs = 0, msgs_posted = 0, msgs_done = 0;

    // ---------------- send queue
    logic [191:0] sq_q[$];
    task automatic post(input bit read, input int qpn, input longint laddr, input longint raddr, input int len);
        logic [191:0] w = '0;
        w[0] = read;
        w[13:8] = qpn;
        w[63:32] = len;
        w[64 +: 48] = laddr;
        w[128 +: 48] = raddr;
        sq_q.push_back(w);
        count_post(len);
    endtask

    // a message posted elsewhere (the register send queue)
    function automatic void count_post(input int len);
        posted_reqs += (len + 4095) / 4096;
        msgs_posted++;
    endfunction

    function automatic bit idle();
        return done_reqs == posted_reqs && sq_q.size() == 0 && !sq_tvalid;
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            sq_tvalid <= 1'b0;
        end else begin
            if (sq_tvalid && sq_tready)
                sq_tvalid <= 1'b0;
            if ((!sq_tvalid || sq_tready) && sq_q.size() > 0) begin
                sq_tdata <= sq_q.pop_front();
                sq_tvalid <= 1'b1;
            end
        end
    end

    always @(posedge clk)
        if (resetn && cq_tvalid) begin
            done_reqs++;
            if (cq_tdata[1])
                msgs_done++;
        end

    // ---------------- source: pat(a)
    longint src_a[$];
    int     src_n[$];
    longint s_addr;
    int     s_left;
    bit     s_busy = 0;
    always @(posedge clk) begin
        if (!resetn) begin
            rd_tvalid <= 1'b0;
            rdq_tready <= 1'b0;
            s_busy = 0;
        end else begin
            if (rdq_tvalid && rdq_tready) begin
                src_a.push_back(rdq_tdata[47:0]);
                src_n.push_back(rdq_tdata[64 +: 32]);
            end
            rdq_tready <= src_a.size() < 6;
            if (rd_tvalid && rd_tready)
                rd_tvalid <= 1'b0;
            if (!rd_tvalid || rd_tready) begin
                if (!s_busy && src_a.size() > 0) begin
                    s_addr = src_a.pop_front();
                    s_left = src_n.pop_front();
                    s_busy = 1;
                end
                if (s_busy && !(stall && $urandom_range(3) == 0)) begin
                    automatic int n = s_left > BYTES ? BYTES : s_left;
                    for (int i = 0; i < BYTES; i++) begin
                        rd_tdata[8*i +: 8] <= i < n ? pat(s_addr + i) : 8'h00;
                        rd_tkeep[i] <= i < n;
                    end
                    rd_tlast <= s_left <= BYTES;
                    rd_tvalid <= 1'b1;
                    s_addr += n;
                    s_left -= n;
                    if (s_left <= 0)
                        s_busy = 0;
                end
            end
        end
    end

    // ---------------- sink: every byte at x must be pat(x + OFF)
    longint snk_a[$];
    int     snk_n[$];
    longint w_addr;
    int     w_got;
    bit     w_busy = 0;
    assign wrq_tready = 1'b1;
    initial wr_tready = 1'b0;

    always @(posedge clk) begin
        if (resetn && wrq_tvalid) begin
            snk_a.push_back(wrq_tdata[47:0]);
            snk_n.push_back(wrq_tdata[64 +: 32]);
        end
        if (resetn && wr_tvalid && wr_tready) begin
            if (!w_busy) begin
                w_addr = snk_a[0];
                w_got = 0;
                w_busy = 1;
            end
            for (int i = 0; i < BYTES; i++)
                if (wr_tkeep[i]) begin
                    if (wr_tdata[8*i +: 8] !== pat(w_addr + w_got + OFF)) begin
                        if (errors < 10)
                            $display("ERROR %m: byte at %h is %h, expected %h", w_addr + w_got,
                                wr_tdata[8*i +: 8], pat(w_addr + w_got + OFF));
                        errors++;
                    end
                    w_got++;
                end
            for (int i = 0; i < BYTES; i++)
                sink_bytes += (wr_tkeep[i] === 1'b1);
            if (wr_tlast) begin
                if (w_got != snk_n[0]) begin
                    if (errors < 10)
                        $display("ERROR %m: packet to %h has %0d bytes, request said %0d", w_addr, w_got, snk_n[0]);
                    errors++;
                end
                void'(snk_a.pop_front());
                void'(snk_n.pop_front());
                w_busy = 0;
            end
        end
        wr_tready <= resetn && (w_busy || snk_a.size() > 0) && !(stall && $urandom_range(3) == 0);
    end
endmodule

// AXI4-Lite master: one access at a time, driven at the falling edge
module rdma_tb_axil (
    input  logic        clk,
    output logic [11:0] awaddr,
    output logic        awvalid,
    input  logic        awready,
    output logic [31:0] wdata,
    output logic [3:0]  wstrb,
    output logic        wvalid,
    input  logic        wready,
    input  logic        bvalid,
    output logic        bready,
    output logic [11:0] araddr,
    output logic        arvalid,
    input  logic        arready,
    input  logic [31:0] rdata,
    input  logic        rvalid,
    output logic        rready
);
    initial begin
        awvalid = 1'b0;
        wvalid = 1'b0;
        bready = 1'b0;
        arvalid = 1'b0;
        rready = 1'b0;
        wstrb = 4'hF;
    end

    semaphore bus = new(1);

    task automatic write(input logic [11:0] a, input logic [31:0] d);
        bit aw_done = 0, w_done = 0;
        bus.get();
        @(negedge clk);
        awaddr = a;
        wdata = d;
        awvalid = 1'b1;
        wvalid = 1'b1;
        while (!(aw_done && w_done)) begin
            @(posedge clk);
            if (awready) aw_done = 1;
            if (wready) w_done = 1;
            @(negedge clk);
            if (aw_done) awvalid = 1'b0;
            if (w_done) wvalid = 1'b0;
        end
        bready = 1'b1;
        do @(posedge clk); while (!bvalid);
        @(negedge clk);
        bready = 1'b0;
        bus.put();
    endtask

    task automatic read(input logic [11:0] a, output logic [31:0] d);
        bus.get();
        @(negedge clk);
        araddr = a;
        arvalid = 1'b1;
        do @(posedge clk); while (!arready);
        @(negedge clk);
        arvalid = 1'b0;
        rready = 1'b1;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        @(negedge clk);
        rready = 1'b0;
        bus.put();
    endtask
endmodule
