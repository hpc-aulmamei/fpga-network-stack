`timescale 1ns / 1ps

// Retransmission buffer of the RoCE stack in URAM.
//
// roce_payload mirrors the payload of every WRITE the transport sends into
// this buffer (write command + data) and reads it back when the transport
// retransmits (read command -> data). At line rate that is a full-rate write
// stream, so the buffer is on chip instead of in off-chip memory.
//
// Command format (MEM_CMD_BITS = 96): [63:0] address, [95:64] length in bytes.
// The address is ({QP, window slot} << log2(PMTU)), see roce_payload: bits
// [16:12] select one of the 32 slots of 4 KiB and
// bits [17 +: QP_BITS] the QP (pid), so QPs 0 .. 2^QP_BITS-1 are covered.
// A request is at most one PMTU (4 KiB: 32 beats of 128 bytes or 64 of 64).
//
// The write port takes a beat every cycle; reads stream a beat per cycle with
// tkeep and tlast regenerated from the length.
module roce_retrans_mem #(
    parameter integer DATA_BITS = 1024,
    parameter integer QP_BITS = 3,
    parameter integer READ_LATENCY = 4
) (
    input  wire            clk,
    input  wire            resetn,

    input  wire            s_wr_cmd_valid,
    output wire            s_wr_cmd_ready,
    input  wire [95:0]     s_wr_cmd_data,

    input  wire [DATA_BITS-1:0]   s_wr_tdata,
    input  wire            s_wr_tlast,
    input  wire            s_wr_tvalid,
    output wire            s_wr_tready,

    input  wire            s_rd_cmd_valid,
    output wire            s_rd_cmd_ready,
    input  wire [95:0]     s_rd_cmd_data,

    output wire [DATA_BITS-1:0]   m_rd_tdata,
    output wire [DATA_BITS/8-1:0] m_rd_tkeep,
    output wire            m_rd_tlast,
    output wire            m_rd_tvalid,
    input  wire            m_rd_tready
);
    localparam integer BYTES = DATA_BITS / 8;
    localparam integer BYTE_BITS = $clog2(BYTES);   // 7 at 1024 bits
    localparam integer BEAT_BITS = 12 - BYTE_BITS;  // beats per 4 KiB slot: 32 at 1024 bits
    localparam integer SLOT_BITS = 5;               // 32 window slots per QP
    localparam integer ADDR_BITS = QP_BITS + SLOT_BITS + BEAT_BITS;

    function automatic [ADDR_BITS-1:0] slot_base(input [63:0] a);
        slot_base = {a[17 +: QP_BITS], a[12 +: SLOT_BITS], {BEAT_BITS{1'b0}}};
    endfunction

    // ---------------- write ----------------
    wire        wc_valid;
    wire [95:0] wc_data;
    wire        wc_pop;

    small_fifo #(.DATA_BITS(96), .DEPTH_BITS(2)) inst_wr_cmd_q (
        .clk(clk), .resetn(resetn),
        .s_valid(s_wr_cmd_valid), .s_ready(s_wr_cmd_ready), .s_data(s_wr_cmd_data),
        .m_valid(wc_valid), .m_ready(wc_pop), .m_data(wc_data)
    );

    reg [BEAT_BITS-1:0] wr_beat;
    assign s_wr_tready = wc_valid;
    wire wr_fire = s_wr_tvalid && s_wr_tready;
    assign wc_pop = wr_fire && s_wr_tlast;

    always @(posedge clk) begin
        if (!resetn)
            wr_beat <= 0;
        else if (wr_fire)
            wr_beat <= s_wr_tlast ? 0 : wr_beat + 1;
    end

    // one register stage in front of the URAM write port
    reg                 we_r;
    reg [ADDR_BITS-1:0] waddr_r;
    reg [DATA_BITS-1:0] wdata_r;
    always @(posedge clk) begin
        we_r <= resetn && wr_fire;
        waddr_r <= slot_base(wc_data[63:0]) + wr_beat;
        wdata_r <= s_wr_tdata;
    end

    // ---------------- read ----------------
    wire        rc_valid;
    wire [95:0] rc_data;
    reg         rc_pop;

    small_fifo #(.DATA_BITS(96), .DEPTH_BITS(2)) inst_rd_cmd_q (
        .clk(clk), .resetn(resetn),
        .s_valid(s_rd_cmd_valid), .s_ready(s_rd_cmd_ready), .s_data(s_rd_cmd_data),
        .m_valid(rc_valid), .m_ready(rc_pop), .m_data(rc_data)
    );

    // beats of the head command: ceil(len / BYTES), at least one
    wire [31:0] rc_len = rc_data[95:64];
    wire [BEAT_BITS:0] rc_beats = (rc_len[31:BYTE_BITS] == 0) ? 1 :
                                  rc_len[BEAT_BITS+BYTE_BITS:BYTE_BITS] + (rc_len[BYTE_BITS-1:0] != 0);
    wire [BYTE_BITS-1:0] rc_tail = rc_len[BYTE_BITS-1:0];  // bytes in the last beat, 0 = BYTES

    localparam integer OQ_DEPTH_BITS = 4;           // 16 beats
    reg [BEAT_BITS:0] rd_beat;
    reg [3:0] in_flight;                            // reads issued, data not yet in the queue
    wire [OQ_DEPTH_BITS:0] q_count;
    wire issue = rc_valid && ((q_count + in_flight) < (1 << OQ_DEPTH_BITS));
    wire last_beat = (rd_beat == rc_beats - 1);

    always @(*) rc_pop = issue && last_beat;

    // sideband travels with the read through the memory latency
    reg [READ_LATENCY-1:0] p_valid;
    reg [READ_LATENCY-1:0] p_last;
    reg [BYTE_BITS-1:0] p_tail [0:READ_LATENCY-1];
    reg [ADDR_BITS-1:0] raddr;
    integer k;

    always @(posedge clk) begin
        if (!resetn) begin
            rd_beat <= 0;
            p_valid <= 0;
        end else begin
            if (issue)
                rd_beat <= last_beat ? 0 : rd_beat + 1;
            p_valid <= {p_valid[READ_LATENCY-2:0], issue};
        end
        p_last <= {p_last[READ_LATENCY-2:0], last_beat};
        p_tail[0] <= rc_tail;
        for (k = 1; k < READ_LATENCY; k = k + 1)
            p_tail[k] <= p_tail[k-1];
        raddr <= slot_base(rc_data[63:0]) + rd_beat[BEAT_BITS-1:0];
    end

    always @(posedge clk) begin
        if (!resetn)
            in_flight <= 0;
        else
            in_flight <= in_flight + issue - (p_valid[READ_LATENCY-1]);
    end

    wire [DATA_BITS-1:0] rdata;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_BITS),
        .ADDR_WIDTH_B(ADDR_BITS),
        .BYTE_WRITE_WIDTH_A(DATA_BITS),
        .CLOCKING_MODE("common_clock"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_PRIMITIVE("ultra"),
        .MEMORY_SIZE((1 << ADDR_BITS) * DATA_BITS),
        .READ_DATA_WIDTH_B(DATA_BITS),
        .READ_LATENCY_B(READ_LATENCY - 1),
        .WRITE_DATA_WIDTH_A(DATA_BITS),
        .WRITE_MODE_B("read_first"),
        .USE_MEM_INIT(0)
    ) inst_mem (
        .clka(clk),
        .ena(1'b1),
        .wea(we_r),
        .addra(waddr_r),
        .dina(wdata_r),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .clkb(clk),
        .rstb(1'b0),
        .enb(1'b1),
        .regceb(1'b1),
        .addrb(raddr),
        .doutb(rdata),
        .sbiterrb(),
        .dbiterrb(),
        .sleep(1'b0)
    );

    // stage READ_LATENCY-1 of the sideband lines up with doutb: the address
    // register is stage 0 and the memory adds READ_LATENCY-1
    wire        d_valid = p_valid[READ_LATENCY-1];
    wire        d_last = p_last[READ_LATENCY-1];
    wire [BYTE_BITS-1:0] d_tail = p_tail[READ_LATENCY-1];
    reg  [BYTES-1:0]     d_keep;
    integer b;
    always @(*) begin
        for (b = 0; b < BYTES; b = b + 1)
            d_keep[b] = !d_last || (d_tail == 0) || (b < d_tail);
    end

    small_fifo #(.DATA_BITS(DATA_BITS + BYTES + 1), .DEPTH_BITS(OQ_DEPTH_BITS)) inst_out_q (
        .clk(clk), .resetn(resetn),
        .s_valid(d_valid), .s_ready(), .s_data({d_last, d_keep, rdata}),
        .m_valid(m_rd_tvalid), .m_ready(m_rd_tready), .m_data({m_rd_tlast, m_rd_tkeep, m_rd_tdata}),
        .count(q_count)
    );
endmodule
