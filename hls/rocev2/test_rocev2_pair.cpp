/*
 * Two complete RoCEv2 endpoints (rocev2_top: ICRC, IPv4, UDP, transport)
 * joined by a wire, at any DATA_WIDTH.
 *
 * rocev2 keeps its state in function statics and has no instance template
 * parameter, so each endpoint runs in its own process. The two processes step
 * in lockstep over a socketpair: every cycle each one sends the beat it puts
 * on the wire (or none) and reads the beat coming from the other side.
 *
 * Node 0 posts RDMA WRITE_ONLY requests (at most WINDOW outstanding, as
 * rdma_flow allows) whose payload it reads from a memory filled with an
 * address-derived pattern; node 1 writes them to its memory. Checked:
 *   - every request completes exactly once and node 1 writes it exactly once,
 *   - every byte node 1 writes matches the pattern of the source address,
 *   - every packet on the wire has a correct IPv4 header (version, length,
 *     header checksum, protocol), UDP header (port 4791, length) and the
 *     length the RoCE headers and payload need,
 *   - the wire carries the expected number of beats per request (rate).
 * The link can drop whole packets.
 *
 *     test_rocev2_pair <clean|sizes|loss|ack-loss|daq|window32>
 */
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "../axi_utils.hpp"
#include "rocev2_config.hpp"
#include "rocev2.hpp"

using namespace hls;

// rocev2.cpp, non-HLS build (rocev2.hpp only declares the template)
void rocev2_top(stream<net_axis<DATA_WIDTH> >& s_axis_rx_data, stream<net_axis<DATA_WIDTH> >& m_axis_tx_data,
                stream<txMeta>& s_axis_sq_meta, stream<ackMeta>& m_axis_rx_ack_meta,
                stream<memCmd>& m_axis_mem_write_cmd, stream<memCmd>& m_axis_mem_read_cmd,
                stream<net_axis<DATA_WIDTH> >& m_axis_mem_write_data, stream<net_axis<DATA_WIDTH> >& s_axis_mem_read_data,
                stream<qpContext>& s_axis_qp_interface, stream<ifConnReq>& s_axis_qp_conn_interface,
                ap_uint<128> local_ip_address,
#ifdef DBG_IBV
                stream<psnPkg>& m_axis_dbg_0, stream<psnPkg>& m_axis_dbg_1, stream<psnPkg>& m_axis_dbg_2,
#endif
                ap_uint<32>& regCrcDropPkgCount, ap_uint<32>& regInvalidPsnDropCount, ap_uint<32>& regRetransCount,
                ap_uint<32>& regIbvCountRx, ap_uint<32>& regIbvCountTx);

namespace {

const int BYTES = DATA_WIDTH / 8;
const uint64_t LOCAL_BASE = 0x200000;
const uint64_t REMOTE_BASE = 0x40000000;
const long STALL_CYCLES = 400000;
const long DRAIN_CYCLES = 20000;

int TOTAL_REQUESTS = 400;
int WINDOW = 16;
int DROP_DATA_PERCENT = 0;
int DROP_ACK_EVERY = 0;
bool RANDOM_SIZES = false;
uint32_t REQUEST_BYTES = 4096;

uint64_t rng = 0x9E3779B97F4A7C15ULL;
uint64_t next_random() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

uint8_t pattern(uint64_t addr) { return (uint8_t)((addr * 2654435761ULL) >> 11) ^ (uint8_t)(addr >> 9); }

// Request i: its size and where it goes. Sizes are multiples of 4 (the stack
// does not pad payloads) and requests do not overlap.
std::vector<uint32_t> sizes;
uint64_t local_addr(long i) { return LOCAL_BASE + (uint64_t)i * 8192 + (i % 7) * 4; }
uint64_t remote_addr(long i) { return REMOTE_BASE + (uint64_t)i * 8192 + (i % 5) * 8; }

// RoCEv2 ICRC over an IPv4 packet (IBA Annex A17): CRC-32 (Ethernet) over
// 8 bytes of 0xFF standing in for the LRH, then the packet with the IPv4 TOS,
// TTL and header checksum, the UDP checksum and the BTH resv8a byte set to
// all ones; sent least significant byte first. On hardware Coyote's RTL
// icrc.sv appends it after the HLS stack (insert_icrc is a pass-through with
// DISABLE_CRC_CALCULATION), so the wire model appends it here.
uint32_t icrc(const std::vector<uint8_t>& p) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = c & 1 ? 0xEDB88320U ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFU;
    auto add = [&](uint8_t b) { c = table[(c ^ b) & 0xff] ^ (c >> 8); };
    for (int i = 0; i < 8; ++i) add(0xff);
    for (size_t i = 0; i < p.size(); ++i) {
        bool ones = i == 1 || i == 8 || i == 10 || i == 11 || i == 26 || i == 27 || i == 28 + 4;
        add(ones ? 0xff : p[i]);
    }
    return ~c;
}

// One wire beat as it crosses the socketpair.
struct Beat {
    uint8_t valid, last, done, pad;
    uint8_t keep[BYTES / 8];
    uint8_t data[BYTES];
};

Beat to_beat(const net_axis<DATA_WIDTH>& w) {
    Beat b;
    memset(&b, 0, sizeof(b));
    b.valid = 1;
    b.last = w.last;
    for (int i = 0; i < BYTES; ++i) {
        b.data[i] = (uint8_t)w.data(i * 8 + 7, i * 8);
        if (w.keep[i]) b.keep[i / 8] |= 1 << (i % 8);
    }
    return b;
}

net_axis<DATA_WIDTH> from_beat(const Beat& b) {
    net_axis<DATA_WIDTH> w;
    for (int i = 0; i < BYTES; ++i) {
        w.data(i * 8 + 7, i * 8) = b.data[i];
        w.keep[i] = (b.keep[i / 8] >> (i % 8)) & 1;
    }
    w.last = b.last;
    return w;
}

void exchange(int fd, const Beat& out, Beat& in) {
    if (write(fd, &out, sizeof(out)) != (ssize_t)sizeof(out)) { perror("write"); exit(3); }
    size_t got = 0;
    while (got < sizeof(in)) {
        ssize_t n = read(fd, (char*)&in + got, sizeof(in) - got);
        if (n <= 0) { perror("read"); exit(3); }
        got += n;
    }
}

struct Endpoint {
    stream<net_axis<DATA_WIDTH> > rx_data, tx_data;
    stream<txMeta> sq;
    stream<ackMeta> ack;
    stream<memCmd> wr_cmd, rd_cmd;
    stream<net_axis<DATA_WIDTH> > wr_data, rd_data;
    stream<qpContext> qp;
    stream<ifConnReq> conn;
#ifdef DBG_IBV
    stream<psnPkg> dbg0, dbg1, dbg2;
#endif
    ap_uint<32> crc_drops, psn_drops, retrans, rx_count, tx_count;
    ap_uint<128> ip;

    void step() {
        rocev2_top(rx_data, tx_data, sq, ack, wr_cmd, rd_cmd, wr_data, rd_data, qp, conn, ip,
#ifdef DBG_IBV
                   dbg0, dbg1, dbg2,
#endif
                   crc_drops, psn_drops, retrans, rx_count, tx_count);
    }
};

// Memory: reads return the pattern, writes are checked against it and counted.
struct Memory {
    std::vector<memCmd> reads;
    uint64_t rd_addr = 0;
    long rd_left = 0;
    bool writing = false;
    uint64_t wr_addr = 0;
    long wr_left = 0;
    std::map<uint64_t, int> writes;     // write command address -> times written
    long bad_bytes = 0, wrong_length = 0, written_bytes = 0;
    std::map<uint64_t, uint64_t> source; // remote address -> local address it must hold
    std::map<uint64_t, long> bad_req;    // remote address -> wrong bytes

    void step(Endpoint& e) {
        if (!e.rd_cmd.empty()) reads.push_back(e.rd_cmd.read());
        if (rd_left == 0 && !reads.empty()) {
            rd_addr = (uint64_t)reads.front().addr;
            rd_left = (long)reads.front().len;
            reads.erase(reads.begin());
        }
        if (rd_left > 0) {
            net_axis<DATA_WIDTH> w;
            w.data = 0;
            w.keep = 0;
            int n = rd_left < BYTES ? (int)rd_left : BYTES;
            for (int i = 0; i < n; ++i) {
                w.data(i * 8 + 7, i * 8) = pattern(rd_addr + i);
                w.keep[i] = 1;
            }
            rd_addr += n;
            rd_left -= n;
            w.last = rd_left == 0;
            e.rd_data.write(w);
        }
        if (!writing && !e.wr_cmd.empty()) {
            memCmd cmd = e.wr_cmd.read();
            wr_addr = (uint64_t)cmd.addr;
            wr_left = (long)cmd.len;
            writes[wr_addr]++;
            writing = true;
        }
        if (writing && !e.wr_data.empty()) {
            net_axis<DATA_WIDTH> w = e.wr_data.read();
            for (int i = 0; i < BYTES; ++i) {
                if (!w.keep[i]) continue;
                auto it = source.upper_bound(wr_addr);
                --it;   // the request this address belongs to
                uint64_t src = it->second + (wr_addr - it->first);
                if ((uint8_t)w.data(i * 8 + 7, i * 8) != pattern(src)) { ++bad_bytes; bad_req[it->first]++; }
                ++wr_addr;
                --wr_left;
                ++written_bytes;
            }
            if (w.last) {
                if (wr_left != 0) ++wrong_length;
                writing = false;
            }
        }
    }
};

// Header checks on the packets a node sends, and the drop decision.
struct Wire {
    std::vector<uint8_t> pkt;
    bool in_packet = false, dropping = false;
    long packets = 0, beats = 0, acks = 0, requests = 0, dropped = 0;
    long bad_ip = 0, bad_udp = 0, bad_len = 0, no_icrc = 0;
    bool pkt_short = false;
    std::map<int, long> opcodes;

    static uint16_t be16(const uint8_t* p) { return (p[0] << 8) | p[1]; }

    void check(const std::vector<uint8_t>& p) {
        ++packets;
        if (getenv("DUMP") && packets <= 2) {
            fprintf(stderr, "packet %ld, %zu bytes:", packets, p.size());
            for (size_t i = 0; i < p.size() && i < 64; ++i) fprintf(stderr, "%s%02x", i % 16 ? " " : "\n  ", p[i]);
            fprintf(stderr, "\n");
        }
        if (p.size() < 20 + 8 + 12) { ++bad_len; return; }
        // rocev2 leaves the IPv4 header checksum to mac_ip_encode, and with
        // DISABLE_CRC_CALCULATION (crc.hpp) it sends no ICRC although the IP
        // and UDP lengths count one: accept a packet 4 bytes short and count it.
        size_t icrc_len = be16(&p[2]) == p.size() ? 4 : 0;
        pkt_short = !icrc_len;
        if (!icrc_len) ++no_icrc;
        if (p[0] != 0x45 || p[9] != 17 || be16(&p[2]) != p.size() + 4 - icrc_len) ++bad_ip;
        if (be16(&p[22]) != 4791 || be16(&p[24]) != p.size() + 4 - icrc_len - 20) ++bad_udp;
        int opcode = p[28];
        opcodes[opcode]++;
        // BTH 12, RETH 16 for WRITE_ONLY, AETH 4 for ACK
        if (opcode == RC_RDMA_WRITE_ONLY) {
            uint32_t len = (p[28 + 12 + 12] << 24) | (p[28 + 12 + 13] << 16) | (p[28 + 12 + 14] << 8) | p[28 + 12 + 15];
            if (p.size() != 20 + 8 + 12 + 16 + len + icrc_len) ++bad_len;
        } else if (opcode == RC_ACK) {
            if (p.size() != 20 + 8 + 12 + 4 + icrc_len) ++bad_len;
        }
    }

    // Packets go on the wire whole, with the ICRC that icrc.sv would append,
    // one beat per cycle; a dropped packet is never sent.
    std::vector<net_axis<DATA_WIDTH> > out;
    size_t out_pos = 0;

    Beat step(Endpoint& e) {
        if (!e.tx_data.empty()) {
            net_axis<DATA_WIDTH> w = e.tx_data.read();
            ++beats;
            if (!in_packet) { pkt.clear(); in_packet = true; }
            for (int i = 0; i < BYTES; ++i)
                if (w.keep[i]) pkt.push_back((uint8_t)w.data(i * 8 + 7, i * 8));
            if (w.last) {
                in_packet = false;
                check(pkt);
                int opcode = pkt.size() > 28 ? pkt[28] : -1;
                bool ack = opcode == RC_ACK;
                if (ack) ++acks; else ++requests;
                bool drop = ack ? (DROP_ACK_EVERY && acks % DROP_ACK_EVERY == 0)
                                : (DROP_DATA_PERCENT && (long)(next_random() % 100) < DROP_DATA_PERCENT);
                dropped += drop;
                if (!drop) {
                    std::vector<uint8_t> frame = pkt;
                    if (pkt_short) {   // the HLS stack left room for the ICRC
                        uint32_t crc = icrc(pkt);
                        for (int k = 0; k < 4; ++k) frame.push_back((uint8_t)(crc >> (8 * k)));
                    }
                    for (size_t off = 0; off < frame.size(); off += BYTES) {
                        net_axis<DATA_WIDTH> f;
                        f.data = 0;
                        f.keep = 0;
                        for (int i = 0; i < BYTES && off + i < frame.size(); ++i) {
                            f.data(i * 8 + 7, i * 8) = frame[off + i];
                            f.keep[i] = 1;
                        }
                        f.last = off + BYTES >= frame.size();
                        out.push_back(f);
                    }
                }
            }
        }
        Beat b;
        memset(&b, 0, sizeof(b));
        if (out_pos < out.size()) {
            b = to_beat(out[out_pos++]);
            if (out_pos == out.size()) { out.clear(); out_pos = 0; }
        }
        return b;
    }
};

bool scenario(const std::string& s) {
    if (s == "clean") return true;
    if (s == "sizes") { RANDOM_SIZES = true; TOTAL_REQUESTS = 1000; return true; }
    if (s == "loss") { DROP_DATA_PERCENT = 3; DROP_ACK_EVERY = 7; return true; }
    if (s == "ack-loss") { DROP_ACK_EVERY = 3; return true; }
    if (s == "daq") { REQUEST_BYTES = 3968; TOTAL_REQUESTS = 4000; return true; }
    if (s == "window32") { WINDOW = 32; TOTAL_REQUESTS = 4000; return true; }
    return false;
}

const ap_uint<16> qp0 = 0x11, qp1 = 0x12;
const ap_uint<24> psn0 = 0xFFFF80, psn1 = 0x3a19d6;   // node 0 crosses the PSN wrap

int run(int node, int fd, const std::string& name) {
    std::ofstream quiet("/dev/null");
    std::streambuf* console = std::cout.rdbuf(quiet.rdbuf());

    static Endpoint e;
    static Memory mem;
    static Wire wire;
    ap_uint<128> ip0 = 0, ip1 = 0;
    // ipv4 takes the remote address from bits 127:96, the local one from 31:0
    ip0(31, 0) = 0x0b43000a; ip0(127, 96) = 0x0b43000a;   // 10.0.67.11, network byte order
    ip1(31, 0) = 0x0c43000a; ip1(127, 96) = 0x0c43000a;
    e.ip = node == 0 ? ip0 : ip1;
    if (node == 0) {
        e.qp.write(qpContext(READY_RECV, qp0, psn1, psn0, 0, 0));
        e.conn.write(ifConnReq(qp0, qp1, ip1, 4791));
    } else {
        e.qp.write(qpContext(READY_RECV, qp1, psn0, psn1, 0, 0));
        e.conn.write(ifConnReq(qp1, qp0, ip0, 4791));
    }
    for (long i = 0; i < TOTAL_REQUESTS; ++i) mem.source[remote_addr(i)] = local_addr(i);

    long posted = 0, completed = 0, extra = 0, bad_slot = 0, cycle = 0, last_progress = 0;
    long first_tx = -1, last_tx = 0;
    bool done = false, peer_done = false, stalled = false;
    long drain = 0;
    (void)peer_done;
    Beat out, in;
    while (true) {
        if (node == 0 && posted < TOTAL_REQUESTS && posted - completed < WINDOW) {
            e.sq.write(txMeta(RC_RDMA_WRITE_ONLY, qp0, 0, 1, posted % WINDOW,
                              local_addr(posted), remote_addr(posted), sizes[posted], 0));
            ++posted;
        }
        e.step();
        mem.step(e);
        out = wire.step(e);
        if (out.valid && node == 0) { if (first_tx < 0) first_tx = cycle; last_tx = cycle; }
        out.done = done;
        exchange(fd, out, in);
        if (in.valid) e.rx_data.write(from_beat(in));
        if (in.done == 2) break;            // node 0 has finished
        peer_done = peer_done || in.done;
        while (!e.ack.empty()) {
            ackMeta a = e.ack.read();
            if (node != 0 || completed == posted) { ++extra; continue; }
            if (!a.cum || a.offs != completed % WINDOW) ++bad_slot;
            ++completed;
            last_progress = cycle;
        }
        ++cycle;
        if (node == 0 && !done && completed == TOTAL_REQUESTS) done = true;
        if (node == 0 && cycle - last_progress > STALL_CYCLES) { stalled = true; done = true; }
        if (node == 0 && done && ++drain > DRAIN_CYCLES) break;
    }
    if (node == 0) {    // tell node 1 to stop; it does not answer
        memset(&out, 0, sizeof(out));
        out.done = 2;
        if (write(fd, &out, sizeof(out)) != (ssize_t)sizeof(out)) perror("write");
    }

    std::cout.rdbuf(console);
    std::cout << std::dec;
    bool ok = true;
    auto fail = [&](const std::string& why) { std::cout << "  FAIL node " << node << ": " << why << '\n'; ok = false; };
    if (wire.bad_ip) fail(std::to_string(wire.bad_ip) + " packets with a bad IPv4 header");
    if (wire.bad_udp) fail(std::to_string(wire.bad_udp) + " packets with a bad UDP header");
    if (wire.bad_len) fail(std::to_string(wire.bad_len) + " packets whose length does not fit their RoCE headers");
    if (extra) fail(std::to_string(extra) + " completions nobody waited for");
    if (node == 0) {
        long payload = 0;
        for (long i = 0; i < TOTAL_REQUESTS; ++i) payload += sizes[i];
        double span = last_tx - first_tx + 1;
        std::cout << name << " w" << DATA_WIDTH << ": node 0 posted " << posted << ", completed " << completed
                  << " in " << cycle << " cycles; sent " << wire.requests << " request packets ("
                  << wire.dropped << " dropped), " << wire.beats << " beats, retransmissions "
                  << e.retrans.to_uint() << "; " << (double)wire.beats / wire.requests << " beats/packet, "
                  << span / wire.requests << " cycles/packet, payload " << 8.0 * payload / span
                  << " bit/cycle (" << 8.0 * payload / span * 250e6 / 1e9 << " Gb/s at 250 MHz); "
                  << wire.no_icrc << "/" << wire.packets << " packets without ICRC\n";
        if (stalled) fail("no completion for STALL_CYCLES");
        if (completed != TOTAL_REQUESTS) fail("not every request completed");
        if (bad_slot) fail(std::to_string(bad_slot) + " completions with the wrong window slot");
    } else {
        int missing = 0, twice = 0;
        for (long i = 0; i < TOTAL_REQUESTS; ++i) {
            auto it = mem.writes.find(remote_addr(i));
            if (it == mem.writes.end()) ++missing; else if (it->second > 1) ++twice;
        }
        std::cout << name << " w" << DATA_WIDTH << ": node 1 wrote " << mem.writes.size() << " requests, "
                  << mem.written_bytes << " bytes, " << mem.bad_bytes << " wrong bytes; sent "
                  << wire.acks << " ACKs (" << wire.dropped << " dropped), PSN drops "
                  << e.psn_drops.to_uint() << '\n';
        if (missing) fail(std::to_string(missing) + " requests never written");
        if (twice) fail(std::to_string(twice) + " requests written twice");
        if (mem.bad_bytes) {
            fail(std::to_string(mem.bad_bytes) + " payload bytes wrong");
            int shown = 0;
            for (long i = 0; i < TOTAL_REQUESTS && shown < 12; ++i) {
                auto it = mem.bad_req.find(remote_addr(i));
                if (it == mem.bad_req.end()) continue;
                std::cout << "    request " << i << ": " << sizes[i] << " bytes (" << sizes[i] % BYTES
                          << " in the last beat), " << it->second << " wrong\n";
                ++shown;
            }
        }
        if (mem.wrong_length) fail(std::to_string(mem.wrong_length) + " writes with the wrong length");
    }
    std::cout.flush();
    return ok ? 0 : 1;
}

} // namespace

int main(int argc, char* argv[]) {
    std::string name = argc > 1 ? argv[1] : "clean";
    if (!scenario(name)) { std::cerr << "unknown scenario " << name << '\n'; return 2; }
    for (long i = 0; i < TOTAL_REQUESTS; ++i)
        sizes.push_back(RANDOM_SIZES ? 4 * (1 + next_random() % 1024) : REQUEST_BYTES);
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) { perror("socketpair"); return 3; }
    pid_t pid = fork();
    if (pid == 0) { close(fds[0]); _exit(run(1, fds[1], name)); }
    close(fds[1]);
    int rc0 = run(0, fds[0], name);
    int status = 0;
    waitpid(pid, &status, 0);
    int rc1 = WIFEXITED(status) ? WEXITSTATUS(status) : 4;
    bool ok = rc0 == 0 && rc1 == 0;
    std::cout << (ok ? "PASS " : "FAIL ") << name << " w" << DATA_WIDTH << '\n';
    return ok ? 0 : 1;
}
