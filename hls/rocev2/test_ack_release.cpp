/*
 * ACK accounting test for the RoCE transport with retransmission enabled.
 *
 * Two ib_transport_protocol instances are joined by a link that can drop
 * packets. Node 0 posts RDMA WRITE_ONLY requests and keeps at most 16 of them
 * outstanding per QP, counted the way rdma_flow counts them: one window slot
 * per request, freed by one entry on m_axis_rx_ack_meta. The test checks that
 * every request is completed exactly once whatever the link drops, and that
 * node 1 wrote every request to memory exactly once.
 *
 * Every scenario runs in its own process because the transport keeps its
 * state in function statics:
 *     test_ack_release <clean|ack-loss|ack-burst|coalesce|data-loss|mixed|two-qp>
 * A drop pattern that repeats with the retransmission round can lose the same
 * packet on every retry; data-loss therefore drops at random.
 */
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <string>

#include "../axi_utils.hpp"
#include "../ib_transport_protocol/ib_transport_protocol.hpp"
#include "rocev2_config.hpp"

using namespace hls;
#include "newFakeDram.hpp"

namespace {

const int TOTAL_REQUESTS = 256;
const int WINDOW = 16;                 // RDMA_N_WR_OUTSTANDING in rdma_flow
const uint32_t REQUEST_BYTES = 1024;
const uint64_t REMOTE_BASE = 0x100000;
const uint64_t LOCAL_BASE = 0x200000;
const long STALL_CYCLES = 400000;      // well past the transport timer back-off
const long DRAIN_CYCLES = 50000;

struct Node {
    stream<ipUdpMeta> rx_meta, tx_meta;
    stream<net_axis<DATA_WIDTH> > rx_data, tx_data;
    stream<txMeta> sq;
    stream<ackMeta> ack;
    stream<qpContext> qp;
    stream<ifConnReq> conn;
    stream<memCmd> wr_cmd, rd_cmd;
    stream<net_axis<DATA_WIDTH> > wr_data, rd_data;
    stream<psnPkg> dbg0, dbg1, dbg2;
    ap_uint<32> psn_drops, retrans, rx_count, tx_count;
};

template <int I>
void step(Node& n) {
    ib_transport_protocol<DATA_WIDTH, I>(
        n.rx_meta, n.rx_data, n.tx_meta, n.tx_data, n.sq, n.ack,
        n.wr_cmd, n.rd_cmd, n.wr_data, n.rd_data, n.qp, n.conn,
#ifdef DBG_IBV
        n.dbg0, n.dbg1, n.dbg2,
#endif
        n.psn_drops, n.retrans, n.rx_count, n.tx_count);
}

// Which packets the link drops. index counts the packets of one kind
// (ACKs or requests) in one direction, starting at 0.
struct DropPolicy {
    int ack_every = 0;       // drop ACK i when i % ack_every == ack_every - 1
    int ack_keep_every = 0;  // keep only every Nth ACK, as if the responder coalesced
    int ack_burst_from = -1; // drop ACKs [from, from + len)
    int ack_burst_len = 0;
    int data_every = 0;      // drop request packet i when i % data_every == data_every - 1
    int data_percent = 0;    // drop request packets at random with this probability
    mutable uint64_t rng = 0x9E3779B97F4A7C15ULL;

    bool dropAck(long i) const {
        if (ack_every && i % ack_every == ack_every - 1) return true;
        if (ack_keep_every && i % ack_keep_every != ack_keep_every - 1) return true;
        if (ack_burst_from >= 0 && i >= ack_burst_from && i < ack_burst_from + ack_burst_len) return true;
        return false;
    }
    bool dropData(long i) const {
        if (data_every && i % data_every == data_every - 1) return true;
        if (data_percent) {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
            return rng % 100 < (uint64_t)data_percent;
        }
        return false;
    }
};

// One direction of the wire: whole packets, one beat per cycle.
struct Link {
    bool busy = false;
    bool dropping = false;
    long acks = 0, requests = 0, dropped_acks = 0, dropped_requests = 0;
    std::map<int, long> opcodes;

    void step(Node& from, Node& to, const DropPolicy& policy) {
        if (!busy) {
            if (from.tx_meta.empty() || from.tx_data.empty()) return;
            ipUdpMeta meta = from.tx_meta.read();
            net_axis<DATA_WIDTH> word = from.tx_data.read();
            int opcode = (int)word.data(7, 0);
            opcodes[opcode]++;
            if (opcode == RC_ACK) {
                dropping = policy.dropAck(acks++);
                dropped_acks += dropping;
            } else {
                dropping = policy.dropData(requests++);
                dropped_requests += dropping;
            }
            if (!dropping) {
                to.rx_meta.write(meta);
                to.rx_data.write(word);
            }
            busy = !word.last;
            return;
        }
        if (from.tx_data.empty()) return;
        net_axis<DATA_WIDTH> word = from.tx_data.read();
        if (!dropping) to.rx_data.write(word);
        busy = !word.last;
    }
};

// Memory behind a node: serve reads, sink writes and record their addresses.
struct Memory {
    newFakeDRAM<DATA_WIDTH> dram;
    bool writing = false;
    std::map<uint64_t, int> writes;

    void step(Node& n) {
        if (!n.rd_cmd.empty()) {
            memCmd cmd = n.rd_cmd.read();
            dram.processRead(cmd, n.rd_data);
        }
        if (!writing && !n.wr_cmd.empty()) {
            memCmd cmd = n.wr_cmd.read();
            writes[(uint64_t)cmd.addr]++;
            writing = true;
        }
        if (writing && !n.wr_data.empty()) {
            writing = !n.wr_data.read().last;
        }
    }
};

// Scenario name -> drop policy and number of QPs.
bool scenarioFor(const std::string& name, DropPolicy& p, int& qps) {
    qps = 1;
    if (name == "clean") return true;
    if (name == "ack-loss") { p.ack_every = 3; return true; }
    if (name == "ack-burst") { p.ack_burst_from = 40; p.ack_burst_len = 3 * WINDOW; return true; }
    if (name == "coalesce") { p.ack_keep_every = 8; return true; }
    if (name == "data-loss") { p.data_percent = 10; return true; }
    if (name == "mixed") { p.ack_every = 4; p.data_every = 13; return true; }
    if (name == "two-qp") { qps = 2; p.ack_every = 4; p.data_percent = 5; return true; }
    return false;
}

// Node 0 QP local[q] <-> node 1 QP remote[q]. QP 1 starts close to the
// 24-bit PSN wrap so the run crosses it.
const ap_uint<16> local_qp[2] = {0x01, 0x02};
const ap_uint<16> remote_qp[2] = {0x00, 0x03};
const ap_uint<24> local_psn[2] = {0xFFFFC0, 0x123456};
const ap_uint<24> remote_psn[2] = {0x3a19d6, 0x654321};

uint64_t remoteAddr(int q, long i) {
    return REMOTE_BASE + q * 0x1000000ULL + i * REQUEST_BYTES;
}

} // namespace

int main(int argc, char* argv[]) {
    const std::string scenario = argc > 1 ? argv[1] : "clean";
    DropPolicy policy;
    int qps;
    if (!scenarioFor(scenario, policy, qps)) {
        std::cerr << "unknown scenario " << scenario << '\n';
        return 2;
    }

    // The transport prints a line per event; keep only the test's verdict.
    std::ofstream quiet("/dev/null");
    std::streambuf* console = std::cout.rdbuf(quiet.rdbuf());

    static Node n0, n1;
    static Link up, down;   // up: node 0 -> node 1, down: node 1 -> node 0
    static Memory m0, m1;

    ap_uint<128> ip0, ip1;
    ip0(127, 64) = 0xfe80000000000000; ip0(63, 0) = 0x92e2baff0b01d4d2;
    ip1(127, 64) = 0xfe80000000000000; ip1(63, 0) = 0x92e2baff0b01d4d3;

    for (int q = 0; q < qps; ++q) {
        n0.qp.write(qpContext(READY_RECV, local_qp[q], remote_psn[q], local_psn[q], 0, 0));
        n1.qp.write(qpContext(READY_RECV, remote_qp[q], local_psn[q], remote_psn[q], 0, 0));
        n0.conn.write(ifConnReq(local_qp[q], remote_qp[q], ip1, 5000));
        n1.conn.write(ifConnReq(remote_qp[q], local_qp[q], ip0, 5000));
    }

    for (int i = 0; i < 10; ++i) { step<0>(n0); step<1>(n1); }

    long posted[2] = {0, 0}, completed[2] = {0, 0};
    long cycle = 0, last_progress = 0, early_acks = 0, foreign_acks = 0, extra_acks = 0;
    int next_qp = 0;
    bool stalled = false;
    auto all_done = [&]() {
        for (int q = 0; q < qps; ++q) if (completed[q] != TOTAL_REQUESTS) return false;
        return true;
    };

    while (true) {
        // one request per cycle, round robin over the QPs with room in their window
        for (int k = 0; k < qps; ++k) {
            int q = (next_qp + k) % qps;
            if (posted[q] < TOTAL_REQUESTS && posted[q] - completed[q] < WINDOW) {
                n0.sq.write(txMeta(RC_RDMA_WRITE_ONLY, local_qp[q], 0, 1, 0,
                                   LOCAL_BASE + posted[q] * REQUEST_BYTES,
                                   remoteAddr(q, posted[q]), REQUEST_BYTES, 0));
                ++posted[q];
                next_qp = (q + 1) % qps;
                break;
            }
        }

        step<0>(n0);
        step<1>(n1);
        up.step(n0, n1, policy);
        down.step(n1, n0, policy);
        m0.step(n0);
        m1.step(n1);

        while (!n0.ack.empty()) {
            ackMeta a = n0.ack.read();
            int q = -1;
            for (int k = 0; k < qps; ++k) if (a.qpn == local_qp[k]) q = k;
            if (q < 0) { ++foreign_acks; continue; }
            if (completed[q] == posted[q]) ++early_acks;   // frees a slot nobody holds
            else ++completed[q];
            last_progress = cycle;
        }
        while (!n1.ack.empty()) { n1.ack.read(); ++foreign_acks; }

        ++cycle;
        if (all_done()) break;
        if (cycle - last_progress > STALL_CYCLES) { stalled = true; break; }
    }

    // Nothing may complete after the last request did.
    for (long i = 0; i < DRAIN_CYCLES; ++i) {
        step<0>(n0); step<1>(n1);
        up.step(n0, n1, policy); down.step(n1, n0, policy);
        m0.step(n0); m1.step(n1);
        while (!n0.ack.empty()) { n0.ack.read(); ++extra_acks; }
    }

    long total_posted = 0, total_completed = 0;
    int missing = 0, duplicated = 0;
    for (int q = 0; q < qps; ++q) {
        total_posted += posted[q];
        total_completed += completed[q];
        for (long i = 0; i < posted[q]; ++i) {
            auto it = m1.writes.find(remoteAddr(q, i));
            if (it == m1.writes.end()) ++missing;
            else if (it->second > 1) ++duplicated;
        }
    }

    std::cout.rdbuf(console);
    std::cout << std::dec << scenario << ": " << qps << " QP, posted " << total_posted
              << ", completed " << total_completed << " in " << cycle << " cycles; acks dropped "
              << down.dropped_acks << "/" << down.acks
              << ", requests dropped " << up.dropped_requests << "/" << up.requests
              << ", retransmissions " << n0.retrans.to_uint()
              << "; extra completions " << early_acks + extra_acks
              << ", writes missing " << missing << ", duplicated " << duplicated << '\n';

    bool ok = true;
    auto fail = [&](const char* why) { std::cout << "  FAIL: " << why << '\n'; ok = false; };
    if (stalled) fail("no completion for STALL_CYCLES, the QP is stuck");
    if (!all_done()) fail("not every request completed");
    if (early_acks || extra_acks) fail("more completions than requests, rdma_flow would free a slot it does not hold");
    if (foreign_acks) fail("completion for the wrong QP or node");
    if (missing) fail("node 1 never wrote some requests");
    if (duplicated) fail("node 1 wrote some requests twice");
    std::cout << (ok ? "PASS " : "FAIL ") << scenario << '\n';
    return ok ? 0 : 1;
}
