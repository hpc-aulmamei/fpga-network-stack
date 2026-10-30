`timescale 1ns / 1ps

/**
 * RoCEv2 ICRC insertion for any data width that is a multiple of 128 bits
 * (512 and 1024 are used).
 *
 * The input is an IPv4 RoCE packet as the HLS stack sends it, without the
 * ICRC (its IP and UDP lengths already count the 4 ICRC bytes); the output is
 * the same packet with the ICRC appended. Packets are a multiple of 4 bytes.
 *
 * ICRC (IBA Annex A17, RoCEv2 over IPv4): CRC-32 (Ethernet) over 8 bytes of
 * 0xFF, then the packet with the IPv4 TOS, TTL and header checksum, the UDP
 * checksum and the BTH resv8a byte replaced by ones (bytes 1, 8, 10, 11, 26,
 * 27 and 32), inverted and sent least significant byte first. The 8-byte
 * prefix is folded into the seed 0xDEBB20E3.
 *
 * Structure: every beat goes into a data FIFO and, in parallel, into a CRC
 * pipeline that never stalls:
 *   P1  register the beat (first beat masked), its byte count and position
 *   P2  for the last beat of a packet, cut the bytes that do not fill a whole
 *       beat into blocks of 64, 32, 16, 8 and 4 bytes (as many as the count
 *       needs, in wire order)
 *   P3  the data part (crc32_g) of a whole beat and of each block
 *   P4  per packet, crc = f(crc) ^ g over the whole beats; only the 32 x 32
 *       state matrix is in this loop
 *   P5..P9  one stage per block size: crc = f(crc) ^ g if the block is used
 *   P10 invert, push into the CRC FIFO
 * The output takes beats from the data FIFO; the last beat of a packet waits
 * for its CRC, which is written into the bytes after the data, or into an
 * extra beat when the last beat is full.
 */
module icrc_core #(
    parameter integer DATA_BITS = 1024,
    parameter integer FIFO_DEPTH = 32       // beats; more than the CRC latency
) (
    input  logic                    aclk,
    input  logic                    aresetn,

    input  logic                    s_tvalid,
    output logic                    s_tready,
    input  logic [DATA_BITS-1:0]    s_tdata,
    input  logic [DATA_BITS/8-1:0]  s_tkeep,
    input  logic                    s_tlast,

    output logic                    m_tvalid,
    input  logic                    m_tready,
    output logic [DATA_BITS-1:0]    m_tdata,
    output logic [DATA_BITS/8-1:0]  m_tkeep,
    output logic                    m_tlast
);
    import icrc_crc32_pkg::*;

    localparam integer BYTES = DATA_BITS / 8;
    localparam integer WORDS = BYTES / 4;              // 4-byte groups per beat
    localparam integer WBITS = $clog2(WORDS + 1);      // count of groups, 0..WORDS
    localparam integer ABITS = $clog2(FIFO_DEPTH);
    localparam logic [31:0] SEED = 32'hdebb20e3;

    // ones in the fields the ICRC does not cover (first beat only)
    localparam logic [DATA_BITS-1:0] MASK =
        (DATA_BITS'(8'hff) << (8 * 1))  | (DATA_BITS'(8'hff) << (8 * 8))  |
        (DATA_BITS'(16'hffff) << (8 * 10)) | (DATA_BITS'(16'hffff) << (8 * 26)) |
        (DATA_BITS'(8'hff) << (8 * 32));

    initial begin
        if (DATA_BITS % 128 != 0 || DATA_BITS > 1024)
            $error("icrc_core: DATA_BITS must be 128 .. 1024 in steps of 128");
    end

    // number of 4-byte groups in a beat (keep is contiguous from bit 0)
    function automatic logic [WBITS-1:0] groups(input logic [BYTES-1:0] keep);
        groups = '0;
        for (int i = 0; i < WORDS; i++)
            if (keep[4 * i]) groups = WBITS'(i + 1);
    endfunction

    // ------------------------------------------------------------------
    // input: data FIFO and the start of the CRC pipeline
    // ------------------------------------------------------------------
    // One slot is always free: the beat at the input is written into it every
    // cycle (no write enable fanning out to the whole FIFO), and the write
    // pointer only moves on a handshake.
    logic [ABITS:0] d_count;
    logic ready;                        // registered: d_count < FIFO_DEPTH - 1
    wire accept = s_tvalid && ready;
    assign s_tready = ready;

    logic first_beat;   // next input beat starts a packet
    always_ff @(posedge aclk) begin
        if (!aresetn) first_beat <= 1'b1;
        else if (accept) first_beat <= s_tlast;
    end

    // P1
    logic                   p1_valid, p1_first, p1_last;
    logic [DATA_BITS-1:0]   p1_data;
    logic [WBITS-1:0]       p1_groups;
    always_ff @(posedge aclk) begin
        p1_valid <= aresetn && accept;
        p1_first <= first_beat;
        p1_last <= s_tlast;
        p1_data <= first_beat ? (s_tdata | MASK) : s_tdata;
        p1_groups <= groups(s_tkeep);
    end

    // P2: the remainder of the last beat in blocks of 16, 8, 4, 2, 1 groups
    // (64, 32, 16, 8, 4 bytes); a whole beat (all groups) has none
    logic                   p2_valid, p2_first, p2_last, p2_whole;
    logic [DATA_BITS-1:0]   p2_data;
    logic [4:0]             p2_use;        // blocks used: [4] 64 B .. [0] 4 B
    logic [511:0]           p2_b64;
    logic [255:0]           p2_b32;
    logic [127:0]           p2_b16;
    logic [63:0]            p2_b8;
    logic [31:0]            p2_b4;
    always_ff @(posedge aclk) begin
        logic [WBITS-1:0] rest;
        int off;
        p2_valid <= p1_valid;
        p2_first <= p1_first;
        p2_last <= p1_last;
        p2_data <= p1_data;
        p2_whole <= p1_groups == WORDS;
        rest = (p1_groups == WORDS) ? '0 : p1_groups;
        p2_use <= rest[4:0];
        off = 0;
        p2_b64 <= DATA_BITS > 512 ? p1_data[0 +: (DATA_BITS > 512 ? 512 : 1)] : '0;
        if (DATA_BITS > 512 && rest[4]) off += 64;
        p2_b32 <= p1_data[8 * off +: 256];
        if (rest[3]) off += 32;
        p2_b16 <= p1_data[8 * off +: 128];
        if (rest[2]) off += 16;
        p2_b8 <= p1_data[8 * off +: 64];
        if (rest[1]) off += 8;
        p2_b4 <= p1_data[8 * off +: 32];
    end

    // P3: data parts
    logic                   p3_valid, p3_first, p3_last, p3_whole;
    logic [4:0]             p3_use;
    logic [31:0]            p3_gbeat, p3_g64, p3_g32, p3_g16, p3_g8, p3_g4;
    always_ff @(posedge aclk) begin
        p3_valid <= p2_valid;
        p3_first <= p2_first;
        p3_last <= p2_last;
        p3_whole <= p2_whole;
        p3_use <= p2_use;
        p3_gbeat <= gbeat(p2_data);
        p3_g64 <= crc32_g64(p2_b64);
        p3_g32 <= crc32_g32(p2_b32);
        p3_g16 <= crc32_g16(p2_b16);
        p3_g8 <= crc32_g8(p2_b8);
        p3_g4 <= crc32_g4(p2_b4);
    end

    function automatic logic [31:0] gbeat(input logic [DATA_BITS-1:0] d);
        if (DATA_BITS == 1024) return crc32_g128(d);
        if (DATA_BITS == 512)  return crc32_g64(d[511:0]);
        if (DATA_BITS == 256)  return crc32_g32(d[255:0]);
        return crc32_g16(d[127:0]);
    endfunction
    function automatic logic [31:0] fbeat(input logic [31:0] c);
        if (DATA_BITS == 1024) return crc32_f128(c);
        if (DATA_BITS == 512)  return crc32_f64(c);
        if (DATA_BITS == 256)  return crc32_f32(c);
        return crc32_f16(c);
    endfunction

    // P4: whole beats of a packet
    logic [31:0]            acc;           // CRC after the whole beats so far
    logic                   p4_valid;
    logic [4:0]             p4_use;
    logic [31:0]            p4_crc, p4_g64, p4_g32, p4_g16, p4_g8, p4_g4;
    always_ff @(posedge aclk) begin
        logic [31:0] c, next;
        c = p3_first ? SEED : acc;
        next = p3_whole ? (fbeat(c) ^ p3_gbeat) : c;
        if (p3_valid) acc <= next;
        p4_valid <= aresetn && p3_valid && p3_last;
        p4_crc <= next;
        p4_use <= p3_use;
        {p4_g64, p4_g32, p4_g16, p4_g8, p4_g4} <= {p3_g64, p3_g32, p3_g16, p3_g8, p3_g4};
    end

    // P5..P9: the blocks of the last beat
    logic [4:0]  r_valid;
    logic [31:0] r_crc [5];
    logic [4:0]  r_use [5];
    logic [31:0] r_g [5][5];               // r_g[stage][block]
    always_ff @(posedge aclk) begin
        r_valid <= {r_valid[3:0], p4_valid};
        // P5: 64 bytes
        r_crc[0] <= p4_use[4] ? (crc32_f64(p4_crc) ^ p4_g64) : p4_crc;
        r_use[0] <= p4_use;
        r_g[0] <= '{p4_g64, p4_g32, p4_g16, p4_g8, p4_g4};
        // P6..P9: 32, 16, 8, 4 bytes
        r_crc[1] <= r_use[0][3] ? (crc32_f32(r_crc[0]) ^ r_g[0][1]) : r_crc[0];
        r_crc[2] <= r_use[1][2] ? (crc32_f16(r_crc[1]) ^ r_g[1][2]) : r_crc[1];
        r_crc[3] <= r_use[2][1] ? (crc32_f8(r_crc[2]) ^ r_g[2][3]) : r_crc[2];
        r_crc[4] <= r_use[3][0] ? (crc32_f4(r_crc[3]) ^ r_g[3][4]) : r_crc[3];
        for (int i = 1; i < 5; i++) begin
            r_use[i] <= r_use[i - 1];
            r_g[i] <= r_g[i - 1];
        end
        if (!aresetn) r_valid <= '0;
    end

    // P10: CRC FIFO (one entry per packet; never more than the data FIFO holds)
    logic [31:0]    c_mem [FIFO_DEPTH];
    logic [ABITS:0] c_wr, c_rd;
    wire            c_empty = c_wr == c_rd;
    wire            c_pop;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            c_wr <= '0;
            c_rd <= '0;
        end else begin
            if (r_valid[4]) begin
                c_mem[c_wr[ABITS-1:0]] <= ~r_crc[4];
                c_wr <= c_wr + 1;
            end
            if (c_pop) c_rd <= c_rd + 1;
        end
    end

    // ------------------------------------------------------------------
    // data FIFO and output
    // ------------------------------------------------------------------
    logic [DATA_BITS-1:0]   d_data [FIFO_DEPTH];
    logic [WBITS-1:0]       d_groups [FIFO_DEPTH];
    logic                   d_last [FIFO_DEPTH];
    logic [ABITS:0]         d_wr, d_rd;
    wire                    d_empty = d_count == 0;

    logic extra;           // the ICRC goes out in a beat of its own next
    wire [DATA_BITS-1:0] h_data = d_data[d_rd[ABITS-1:0]];
    wire [WBITS-1:0]     h_groups = d_groups[d_rd[ABITS-1:0]];
    wire                 h_last = d_last[d_rd[ABITS-1:0]];
    wire [31:0]          h_crc = c_mem[c_rd[ABITS-1:0]];

    // the head beat can go when it is not a last beat or its CRC is ready
    wire head_ok = !d_empty && (!h_last || !c_empty);
    assign m_tvalid = extra ? 1'b1 : head_ok;
    wire send = m_tvalid && m_tready;
    wire d_pop = send && !extra;
    assign c_pop = send && (extra || (h_last && h_groups != WORDS));

    always_comb begin
        m_tdata = h_data;
        m_tkeep = '0;
        for (int i = 0; i < WORDS; i++)
            if (i < h_groups) m_tkeep[4 * i +: 4] = 4'hf;
        m_tlast = h_last;
        if (extra) begin
            m_tdata = '0;
            m_tdata[31:0] = h_crc;
            m_tkeep = '0;
            m_tkeep[3:0] = 4'hf;
            m_tlast = 1'b1;
        end else if (h_last && h_groups != WORDS) begin
            for (int i = 0; i < WORDS; i++)
                if (i == h_groups) m_tdata[32 * i +: 32] = h_crc;
            for (int i = 0; i < WORDS; i++)
                if (i == h_groups) m_tkeep[4 * i +: 4] = 4'hf;
        end else if (h_last) begin
            m_tlast = 1'b0;                 // full last beat: the ICRC follows
        end
    end

    wire [ABITS:0] d_count_next = d_count + (accept ? 1 : 0) - (d_pop ? 1 : 0);

    always_ff @(posedge aclk) begin
        d_data[d_wr[ABITS-1:0]] <= s_tdata;
        d_groups[d_wr[ABITS-1:0]] <= groups(s_tkeep);
        d_last[d_wr[ABITS-1:0]] <= s_tlast;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            d_wr <= '0;
            d_rd <= '0;
            d_count <= '0;
            ready <= 1'b0;
            extra <= 1'b0;
        end else begin
            if (accept)
                d_wr <= d_wr + 1;
            if (d_pop) d_rd <= d_rd + 1;
            d_count <= d_count_next;
            ready <= d_count_next < FIFO_DEPTH - 1;
            if (send) extra <= !extra && h_last && h_groups == WORDS;
        end
    end
endmodule
