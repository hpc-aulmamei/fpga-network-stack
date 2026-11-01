# RDMA stack IP (`rdma_100`, `rdma_200`)

A RoCE v2 endpoint as one Vivado IP: reliable connection, RDMA WRITE and
RDMA READ over IPv4 / UDP, with ARP and ICMP (ping), between an Ethernet MAC
and a payload memory. It is built from the HLS IPs of this repository
(`rocev2`, `ip_handler`, `mac_ip_encode`, `arp_server_subnet`,
`icmp_server`) and the RTL in `rtl/`.

| IP         | Data path         | Line rate | Clock (default) |
|------------|-------------------|-----------|-----------------|
| `rdma_100` | 512 bits (64 B)   | 100G      | 250 MHz         |
| `rdma_200` | 1024 bits (128 B) | 200G      | 250 MHz         |

## Build

Vitis HLS and Vivado (2025.1 tested) on `PATH`, CMake 3.15 or newer,
Python 3.

```
mkdir build && cd build
cmake .. -DFPGA_PART=xcv80-lsva4737-2MHP-e-S     # the device the HLS IPs are built for
make rdma_200                                     # and / or make rdma_100
```

The IPs land in `build/iprepo/rdma_200/` and `build/iprepo/rdma_100/`.
Each target builds its HLS IPs at its own width in a build directory of its
own (`build/rdma_<n>/hls`), whatever `DATA_WIDTH` / `EN_RDMA` say, and only
again when a source under `hls/` changes.

| CMake variable      | Default                  | Meaning |
|---------------------|--------------------------|---------|
| `FPGA_PART`         | `xcu55c-fsvh2892-2L-e`   | part the HLS IPs are synthesized for |
| `CLOCK_PERIOD`      | `4`                      | HLS target clock period [ns] |
| `CLOCK_UNCERTAINTY` | `25%`                    | HLS clock uncertainty |
| `RDMA_IPREPO`       | `<build>/iprepo`         | where the packaged IPs go |
| `RDMA_IP_VENDOR`    | `ethz.systems.fpga`      | IP vendor (VLNV `<vendor>:rdma:rdma_<n>:<version>`) |
| `RDMA_IP_VERSION`   | `1.0`                    | IP version |
| `RDMA_HLS_JOBS`     | `5`                      | HLS IPs synthesized in parallel |

Other targets:

- `make rdma_200_sim` (`rdma_100_sim`): two IPs back to back over a link
  model in xsim, every payload byte checked; PASS / FAIL at the end, log in
  `build/rdma_<n>/sim/xsim.out`. Plusargs through the environment, e.g.
  `RDMA_SIM_ARGS="+DROP=50 +N=400" make rdma_200_sim` (see
  `sim/rdma/tb_rdma_stack.sv`).
- `make rdma_200_ooc` (`rdma_100_ooc`): the IP in a block design
  (`validate_bd_design`), then out-of-context synthesis, place and route of
  its sources at `CLOCK_PERIOD`; reports in `build/rdma_<n>/ooc/`.

## Use

**Block design:** add `build/iprepo` (or the IP directory) to the project's
IP repositories (Settings > IP > Repository) and add *RDMA stack 200G* from
the catalog. `s_axil` is an AXI4-Lite slave with a 4 KiB address block (give
it an address in the Address Editor); all streams are AXI4-Stream
interfaces; everything is associated with `aclk` / `aresetn`.

Minimal bring-up through the registers (offsets below): MAC (`0x020`,
`0x024`), IPv4 address (`0x028`), an ARP lookup of each peer (`0x02C`), one
QP per connection (`0x040` .. `0x05C`); then post messages either on
`s_axis_sq` or through the register send queue (`0x080` .. `0x098`), serve
the payload streams, and count completions (`m_axis_cq` or `0x100`).

**RTL:** compile the files of `build/iprepo/rdma_200/rdma_200.f` (paths
relative to that directory, top level last; `.sv` files as
SystemVerilog) and instantiate module `rdma_200`. Every module and package
inside carries the prefix `rdma_200_` (`rdma_100_`), so both IPs, or the
same RTL elsewhere in a design, can coexist. The IP uses XPM memories and
FIFOs only (no other Xilinx IP).

## Clock, reset, throughput

One clock, `aclk`, for everything; `aresetn` is synchronous, active low,
and should be held for at least 16 cycles. At 250 MHz the 1024-bit path
carries 256 Gb/s and the 512-bit path 128 Gb/s, so each IP keeps up with its
line rate (the MAC side usually needs a clock domain crossing, e.g. 200G
DCMAC at 391 MHz with 512 bits, or 100G CMAC at 322 MHz with 512 bits).

Simulated payload rates (4 KiB WRITEs, link model at line rate with
Ethernet framing overhead): see *Verification* below. On hardware the same
RTL (V80, DCMAC, 1024 bits at 230 MHz) ran WRITEs and READs at 193.5 Gb/s
and a two-stream data acquisition at 187.4 Gb/s with no loss.

## Interfaces

Addresses (IPv4, MAC) have their first octet in the top bits:
10.0.0.1 is `32'h0a000001`. Multi-word `tdata` layouts are given in 32-bit
words, word 0 in bits 31:0. Unused bits are zero.

### Network: `s_axis_rx`, `m_axis_tx`

Ethernet frames without FCS (destination MAC first, in byte 0), `tkeep`
contiguous from byte 0, only the last beat partial.

- TX frames are padded to 60 bytes (`TX_PAD = 1`), since a MAC that appends
  the FCS may not pad.
- The stack checks no ICRC on received packets: frames with a bad FCS must
  not reach it. Either the MAC drops them, or set `RX_FCS_FILTER = 1` and
  drive `s_axis_rx_tuser` = bad FCS on the last beat (CMAC / DCMAC style).
  The filter is store and forward with a buffer of
  2^`RX_FCS_FILTER_ADDR_BITS` beats and ignores `tready` (a MAC cannot be
  stalled): `s_axis_rx_tready` is then always 1 and frames that do not fit
  are dropped and counted (STATS 15).

### Registers: `s_axil` (AXI4-Lite, 32 bits, 4 KiB)

All registers are 32 bits. They take whole 32-bit writes only (all four
byte strobes); other writes are answered and ignored. Reads have no side
effects and a repeated write only repeats its configuration, so the
interface is safe behind paths that split reads or deliver a write twice
(PCIe BARs through a NoC). 64-bit values: low word at `a`, high at `a + 4`,
not latched: read HI, LO, HI and again if the two HI reads differ.

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x000` | ID | R | `0x52444D41` ("RDMA") |
| `0x004` | VERSION | R | `0x00010000`: 1.0 |
| `0x008` | CONFIG | R | [11:0] `DATA_BITS`, [15:12] `RT_QP_BITS`, [23:16] `WR_WINDOW`, [31:24] `RD_WINDOW` |
| `0x00C` | SCRATCH | RW | |
| `0x010` / `0x014` | CYCLES | R | `aclk` cycles since reset (64 bit) |
| `0x020` | MAC_LO | RW | own MAC, bits 31:0 (reset `02:00:00:00:00:00`) |
| `0x024` | MAC_HI | RW | own MAC, bits 47:32 |
| `0x028` | IP | RW | own IPv4 address (reset 10.0.0.1). Subnet 255.255.255.0, the own address is the gateway. MAC and IP go to the stack whenever they change |
| `0x02C` | ARP_LOOKUP | RW | write: resolve this IPv4 address (see below) |
| `0x030` | PENDING | R | [0] ARP lookup, [1] QP setup not yet taken by the stack |
| `0x040` | QP_LOCAL_QPN | RW | local QPN (0 .. 63) |
| `0x044` | QP_REMOTE_QPN | RW | remote QPN (24 bit) |
| `0x048` | QP_LOCAL_PSN | RW | the first PSN expected **from** the peer |
| `0x04C` | QP_REMOTE_PSN | RW | the first PSN sent **to** the peer |
| `0x050` | QP_REMOTE_IP | RW | the peer's IPv4 address |
| `0x054` | QP_REMOTE_PORT | RW | the peer's UDP port (0 = 4791) |
| `0x058` | QP_RKEY | RW | r_key |
| `0x05C` | QP_SET | RW | write: send the QP fields to the stack. [1:0] 0 = connect (all fields), 1 = r_key only, 2 = remote PSN only |
| `0x080` | SQ_CTRL | RW | [0] 0 = RDMA WRITE, 1 = RDMA READ; [13:8] QPN |
| `0x084` | SQ_LEN | RW | message length in bytes, a multiple of 4 (bits 1:0 are dropped) |
| `0x088` / `0x08C` | SQ_LADDR | RW | local address (48 bit): WRITE source / READ destination |
| `0x090` / `0x094` | SQ_RADDR | RW | remote virtual address (48 bit) |
| `0x098` | SQ_POST | RW | write a value different from the one it reads (read, add 1, write) to queue the message above. Taken only when the 16-deep queue has room: read it back, and if it still has the old value, write again later. A repeated value queues nothing |
| `0x09C` | SQ_STATUS | R | [4:0] messages queued, [8] queue full |
| `0x0A0` / `0x0A4` | SQ_REQS | R | requests (of up to 4 KiB) handed to the transport, from both send queues |
| `0x100` / `0x104` | CQ_COUNT | R | completions (one per request) |
| `0x108` / `0x10C` | CQ_MSGS | R | completions that end a message |
| `0x110` | CQ_LAST | R | the last completion, as on `m_axis_cq` |
| `0x1FC` | TX_STALLED | R | [0] `m_axis_tx` has not moved for 2^16 cycles with data waiting |
| `0x200` + 4 i | STATS | R | 32-bit counters from reset, i = 0 .. 15: RX frames, TX frames, ARP RX, ARP TX, ICMP RX, ICMP TX, RoCE RX, RoCE TX (packets into / out of the transport), PSN drops (out-of-sequence packets), retransmissions, ICRC drops, ACK hold cycles (`ACK_GAP_CYCLES`), TX packets trimmed, stray completions (transport completions with nothing outstanding: should stay 0), bad-FCS frames dropped, RX frames dropped for room (`RX_FCS_FILTER`) |

**ARP:** the stack resolves addresses by itself, but **a packet to an
unresolved address is dropped** and only sent again by the transport's
retransmission timer, so look up every peer when setting up (and give it a
few microseconds) to avoid that delay on the first request.

**QPs:** the two ends of a connection swap the PSNs: if node A has local
0x100 / remote 0x300, node B has local 0x300 / remote 0x100. Updates 1 and 2
use the transport's selective update (the `qp_interface` virtual-address
codes 0xDEADBEEF / 0xFEEDBEEF, which the IP sets internally).

### Send queue: `s_axis_sq` (192 bits)

| Word | Bits | Field |
|------|------|-------|
| 0    | 0    | 0 = RDMA WRITE, 1 = RDMA READ |
| 0    | 13:8 | QPN |
| 1    | 31:0 | length in bytes: a multiple of 4, greater than 0 |
| 2, 3 | 47:0 | local address: WRITE source / READ destination |
| 4, 5 | 47:0 | remote virtual address |

The same layout as the register send queue; the two are served in turn,
message by message, when both have one waiting. A message is split into
requests of at most 4 KiB (one PMTU each: WRITE_ONLY / READ_REQUEST
packets), and the stack accepts the next message when the last request has
been queued. A QP has at most `WR_WINDOW` WRITE
and `RD_WINDOW` READ requests outstanding; `s_axis_sq_tready` stays low
while the request at the head waits for its window.

### Completions: `m_axis_cq` (32 bits, no `tready`)

| Bits | Field |
|------|-------|
| 0    | 1 = READ, 0 = WRITE |
| 1    | the last request of its message |
| 13:8 | QPN |

One entry per request (so one per 4 KiB); bit 1 marks the message as done.
Per QP, WRITEs and READs each complete in posting order. A WRITE completes
when the peer acknowledged it, a READ when its last response arrived (and its
payload went out on `m_axis_wr`). There is no back-pressure: take an entry
in the cycle it is valid, or buffer it.

### Payload: `m_axis_rd_req` + `s_axis_rd`, `m_axis_wr_req` + `m_axis_wr`

Request (128 bits) on both request streams:

| Word | Bits  | Field |
|------|-------|-------|
| 0, 1 | 47:0  | address |
| 2    | 31:0  | length in bytes |
| 3    | 4:0   | InfiniBand opcode of the packet |
| 3    | 13:8  | QPN |
| 3    | 16    | last packet of the message |

- **Source** (`m_axis_rd_req` -> `s_axis_rd`): the stack asks for the
  payload it sends: a WRITE's data at its local address, or the data of a
  READ request it serves, at the remote virtual address the peer asked for.
  Answer every request with one packet of exactly that length on
  `s_axis_rd`, in request order, first byte in byte 0, `tlast` on the last
  beat.
- **Sink** (`m_axis_wr_req` -> `m_axis_wr`): incoming WRITE payload (at
  the address the peer wrote to) and READ response payload (at the local
  address of the READ). One packet per request, in order.

Addresses are 48-bit and passed through untouched: protection (r_key
checks) and address translation are up to the user.

**Retransmission:** WRITEs on QPs 0 .. 2^`RT_QP_BITS`-1 are retransmitted
from an on-chip buffer (UltraRAM, 128 KiB per QP: 32 slots of 4 KiB). For
the other QPs the stack asks the source again for the same address, so the
source must still hold a WRITE's data until it completes. READ responses
are always re-read from the source.

## Parameters

| Parameter                 | Default | Meaning |
|---------------------------|---------|---------|
| `DATA_BITS`               | 512 / 1024 | fixed by the IP (the HLS IPs' width) |
| `RT_QP_BITS`              | 3       | QPs 0 .. 2^n-1 retransmit WRITEs from on-chip memory (2^n x 128 KiB) |
| `WR_WINDOW`               | 32      | outstanding WRITE requests per QP (<= 32) |
| `RD_WINDOW`               | 32      | outstanding READ requests per QP (<= 32) |
| `ACK_GAP_CYCLES`          | 20      | minimum cycles between ACKs into the transport (its retransmitter needs them; must stay below the cycles per 4 KiB packet) |
| `TX_PAD`                  | 1       | pad TX frames to 60 bytes |
| `RX_FCS_FILTER`           | 0       | drop RX frames flagged by `s_axis_rx_tuser` |
| `RX_FCS_FILTER_ADDR_BITS` | 9       | its buffer, 2^n beats |

## Inside

```
s_axis_rx -> [FCS filter] -> ip_handler -+-> arp_server_subnet --------------------+
                                          +-> 1024/64 -> icmp_server -> 64/1024 ---+  |
                                          +-> roce_engine                           |  |
                                                FIFO -> roce_ack_pacer -> rocev2    |  |
                                                rocev2 -> roce_tx_trim -> icrc_core |  |
                                                roce_flow (windows, completions)    |  |
                                                roce_payload + roce_retrans_mem     |  |
       roce_engine, icmp -> IP merge -> mac_ip_encode -> frame merge (+ARP) -> pad -> m_axis_tx
```

`rtl/rdma_stack.sv` is the top level (send queue splitting and arbitration,
completions, QP and address handover), `rtl/rdma_ctrl.sv` the registers,
`rtl/eth_roce_stack.sv` the stack itself; the comment at the
head of every file describes its block. `rtl/scripts/rdma_sources.py`
collects one IP's sources (prefixing every module), `rdma_package.tcl`
packages them, `rdma_ooc.tcl` checks the result.

## Transport fixes in `rocev2`

The two-node simulation below found four faults in the transport
(`hls/ib_transport_protocol/`) that are present in the upstream stack. They
show up once READs and WRITEs share a link, or once a frame is lost; all are
fixed here:

1. **TX payload order.** `mem_cmd_merger` fetched payload with the READ
   responses first, while `meta_merger` emitted the headers ACKs first, then
   READ responses, then local requests. `tx_pkg_arbiter` sorts the payload
   into small per-type FIFOs, and `append_payload` takes it in header order:
   when the two orders differ these FIFOs fill and TX stops. `meta_merger`
   now writes the payload order into `tx_memCmdOrderFifo` and
   `mem_cmd_merger` follows it.
2. **Responses out of PSN order.** A responder sent the ACK of a WRITE before
   the response of a READ received ahead of it. The requester's retransmitter
   releases in PSN order and stops at the READ, so the WRITE never completed
   (until the transport timer resent it). `rx_exh_fsm` now writes the order
   of ACKs and READ requests into `rx_respOrderFifo`; `meta_merger` answers in
   that order (NAKs and duplicate ACKs are not ordered).
3. **Retransmission against new requests.** While the retransmitter replays a
   QP it takes no new entries; `local_req_handler` (blocked writing a new
   entry) and `generate_ibh` (blocked on `tx2retrans_insertMeta`, depth 2) then
   stopped the replay they waited for. `local_req_handler` now takes a request
   only when its entry fits, and `tx2retrans_insertMeta` is as deep as
   `tx2retrans_insertAddrLen`.
4. **Lost READ response.** The requester took READ responses by the PSN it
   expected next, which the ACKs of later requests also move. After a lost
   READ response and such an ACK it took the responses of the next READ and
   wrote them to the address of the unanswered one. Now every READ response
   goes to the retransmitter (`retransmitter.hpp`), which takes only the
   packet the oldest outstanding READ waits for and drops the others
   (`retransRdInit.drop`, `pkgSplit.drop`). A later response or an ACK beyond
   that READ is an implied NAK: everything from the READ on is sent again at
   once instead of after the transport timer.

## Verification

`sim/rdma/tb_rdma_stack.sv`: two IPs, a link model at line rate (frame
bytes + 24 for FCS, preamble and inter-frame gap; `+DROP=n` drops one RoCE
frame in n at random), payload models that check every byte and the length of
every packet. Everything is set up through `s_axil`: ID and CONFIG check,
MAC and IP, ARP, QP setup (QPs 1 and 2 with the retransmission buffer, QP 12
without), one small WRITE through the register send queue, `+N` 4 KiB WRITEs and READs
(throughput), `+MIXED` random messages of 4 B .. 20 KiB in both directions
on all three QPs, 1 in `+REG_POSTS` (8) of them through the register send
queue and the others on `s_axis_sq`; then all messages must have completed,
no byte may differ, the completion registers must agree with the models, and
without loss there must be no retransmission or PSN drop.

`make rdma_<n>_sim` runs it (`RDMA_SIM_ARGS="+N=200 +MIXED=200 +DROP=50"`,
`+STALL=1` for a stalling source / sink, `+SEED=n`, `+MIX_OPS`, `+MIX_DIR`,
`+MIX_QP`, `+MIX_ALIGN` to narrow the random messages down).

Results (xsim 2025.1, 250 MHz; payload rates, the wire carries 2.4 % more for
the headers of a 4 KiB message, preamble and gap included):

|                                         | `rdma_100`     | `rdma_200`     |
|-----------------------------------------|----------------|----------------|
| 200 x 4 KiB WRITE                       | 96.3 Gb/s      | 189.0 Gb/s     |
| 200 x 4 KiB READ                        | 96.0 Gb/s      | 188.3 Gb/s     |
| 200 random messages, both ways (sum)    | 157.9 Gb/s     | 301.1 Gb/s     |
| the same with stalling source and sink  | pass           | pass           |
| 2 % random frame loss, all of the above | pass, 71 lost  | pass, 90 lost  |

At line rate the 4 KiB WRITEs and READs fill the link: 41.9 cycles per
message on the wire at 200G, 43.3 measured including start and end.

Loss: a gap in a request stream is answered with one NAK (go-back-N from
there), a lost READ response is found by the next response or ACK (implied
NAK); both resend at once. A lost NAK or the loss of the last packet of a
burst is only recovered by the transport timer: about 0.6 ms at 250 MHz
(1 ms for a 6.4 ns clock with 500 QPs, `hls/ib_transport_protocol/transport_timer.hpp`),
then 5, 12 and 64 ms on repeated retries.

`make rdma_<n>_ooc` on `xcv80-lsva4737-2MHP-e-S` at 4 ns (port paths
excluded):

| IP         | WNS       | LUTs   | FFs    | BRAM tiles | URAM |
|------------|-----------|--------|--------|------------|------|
| `rdma_100` | +0.005 ns | 88.5 k | 169 k  | 51         | 30   |
| `rdma_200` | +0.001 ns | 117 k  | 265 k  | 102        | 30   |
