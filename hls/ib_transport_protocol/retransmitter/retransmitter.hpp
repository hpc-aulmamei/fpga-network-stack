/************************************************
Copyright (c) 2019, Systems Group, ETH Zurich.
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software
without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
************************************************/
#pragma once

#include "../../axi_utils.hpp"
#include "../ib_transport_protocol.hpp"
using namespace hls;

const uint32_t META_TABLE_SIZE = 2000;

struct retransEvent;

struct retransUpdate
{
	ap_uint<16> qpn;
	ap_uint<24> latest_acked_req; //TODO rename?
    ibOpCode op_code;
	retransUpdate() {}
	retransUpdate(ap_uint<16> qpn, ap_uint<24> psn, ibOpCode op_code)
		:qpn(qpn), latest_acked_req(psn), op_code(op_code) {}
};

// The retransmitter's verdict on one READ response packet: the packet is the
// one the oldest outstanding READ waits for (laddr, lst, host of that READ), or
// it is dropped
struct retransRdInit
{
    ap_uint<64> laddr;
    ap_uint<1>  lst;
    ap_uint<1>  host;
    bool        drop;
    retransRdInit()
        :laddr(0), lst(0), host(0), drop(true) {}
    retransRdInit(ap_uint<64> laddr, ap_uint<1> lst, ap_uint<1> host)
        :laddr(laddr), lst(lst), host(host), drop(false) {}
};

struct retransmission
{
	ap_uint<16> qpn;
	ap_uint<24> psn;
	//bool		implicit; //TODO or remove
	retransmission() {}
	retransmission(ap_uint<16> qpn)
		:qpn(qpn), psn(0) {}
	retransmission(ap_uint<16> qpn, ap_uint<24> psn)
		:qpn(qpn), psn(psn) {}
};

struct retransMeta
{
	ap_uint<16> qpn;
	ap_uint<24> psn;
	ibOpCode	opCode;
	retransMeta() {}
	retransMeta(ap_uint<16> qpn, ap_uint<24> psn, ibOpCode op)
		:qpn(qpn), psn(psn), opCode(op){}
};

struct retransAddrLen
{
	ap_uint<64> localAddr;
	ap_uint<64> remoteAddr;
	ap_uint<32> length;
    ap_uint<1>  lst;
    ap_uint<6>  offs;
    ap_uint<1>  host;
	bool        fence;  // no request: the requests before it have all been issued
	retransAddrLen()
		:fence(false) {}
	retransAddrLen(ap_uint<64> laddr, ap_uint<64> raddr, ap_uint<32> len, ap_uint<1> lst, ap_uint<6> offs, ap_uint<1> host)
		:localAddr(laddr), remoteAddr(raddr), length(len), lst(lst), offs(offs), host(host), fence(false) {}
	retransAddrLen(bool f)
		:localAddr(0), remoteAddr(0), length(0), lst(0), offs(0), host(0), fence(f) {}
};

struct retransEntry
{
	ap_uint<16> qpn;
	ap_uint<24> psn;
	ibOpCode	opCode;
	ap_uint<64> localAddr;
	ap_uint<64> remoteAddr;
	ap_uint<32> length;
    ap_uint<1>  lst;
    ap_uint<6>  offs;
    ap_uint<1>  host;
	retransEntry() {}
	retransEntry(ap_uint<16> qpn, ap_uint<24> psn, ibOpCode op, ap_uint<64> laddr, ap_uint<64> raddr, ap_uint<32> len, ap_uint<1> lst, ap_uint<6> offs, ap_uint<1> host)
		:qpn(qpn), psn(psn), opCode(op), localAddr(laddr), remoteAddr(raddr), length(len), lst(lst), offs(offs), host(host) {}
	retransEntry(retransMeta meta, retransAddrLen addrlen)
		:qpn(meta.qpn), psn(meta.psn), opCode(meta.opCode), localAddr(addrlen.localAddr), remoteAddr(addrlen.remoteAddr), length(addrlen.length), lst(addrlen.lst), offs(addrlen.offs), host(addrlen.host) {}
};

struct retransPointerEntry
{
	ap_uint<16>	head;
	ap_uint<16> tail;
	bool valid;
};

typedef enum {INSERT, RELEASE, RX_RETRANS, TIMER_RETRANS} retransOperation ;

struct pointerMeta
{
	retransOperation	op;
	//ap_uint<16>			qpn;
	ap_uint<24>			psn;
	retransPointerEntry entry;
	pointerMeta() {}
	pointerMeta(retransOperation op, ap_uint<24> psn, retransPointerEntry e)
		:op(op), psn(psn), entry(e) {}
};

struct pointerUpdate
{
	ap_uint<16>	qpn;
	retransPointerEntry entry;
	pointerUpdate() {}
	pointerUpdate(ap_uint<16> qpn, retransPointerEntry e)
		:qpn(qpn), entry(e) {}
};

struct retransMetaEntry
{
	ap_uint<24> psn;
	ap_uint<16> next;
	ibOpCode	opCode;
	ap_uint<64> localAddr;
	ap_uint<64> remoteAddr;
	ap_uint<32> length;
    ap_uint<1>  lst;
    ap_uint<6>  offs;
    ap_uint<1>  host;
	bool valid;
	bool isTail;
	retransMetaEntry() {}
	retransMetaEntry(retransEntry& e)
		:psn(e.psn), next(0), opCode(e.opCode), localAddr(e.localAddr), remoteAddr(e.remoteAddr), length(e.length), lst(e.lst), offs(e.offs), host(e.host), valid(true), isTail(true) {}
	retransMetaEntry(ap_uint<16> next)
		:next(next) {}
};

struct retransMetaReq
{
	ap_uint<16> idx;
	retransMetaEntry entry;
	bool write;
	bool append;
	retransMetaReq() {}
	retransMetaReq(ap_uint<16> idx)
		:idx(idx), write(false),  append(false) {}
	retransMetaReq(ap_uint<16> idx, ap_uint<16> next)
		:idx(idx), entry(retransMetaEntry(next)), write(false), append(true) {}
	retransMetaReq(ap_uint<16> idx, retransMetaEntry e)
		:idx(idx), entry(e), write(true), append(false) {}
};

struct pointerReq
{
	ap_uint<16>	qpn;
	bool		lock;
	pointerReq() {}
	pointerReq(ap_uint<16> qpn)
		:qpn(qpn), lock(false) {}
	pointerReq(ap_uint<16> qpn, bool l)
		:qpn(qpn), lock(l) {}
};

/*********************IMPLEMENTATION*********************/

// True if PSN a comes before PSN b in 24-bit serial number order
inline bool psn_before(ap_uint<24> a, ap_uint<24> b)
{
#pragma HLS INLINE
	ap_uint<24> distance = b - a;
	return distance != 0 && distance < 0x800000;
}

template <int INSTID = 0>
void retrans_pointer_table(	
    stream<pointerReq>&			    pointerReqFifo,
	stream<pointerUpdate>&			pointerUpdFifo,
	stream<retransPointerEntry>& 	pointerRspFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

	static retransPointerEntry ptr_table[MAX_QPS];
#if defined( __VITIS_HLS__)
	#pragma HLS bind_storage variable=ptr_table type=RAM_T2P impl=BRAM
#else
	#pragma HLS RESOURCE variable=ptr_table core=RAM_T2P_BRAM
#endif

	static ap_uint<16> pt_lockedQP;
	static bool pt_isLocked = false;
	static bool pt_wait = false;
	static pointerReq pt_req;

	pointerUpdate upd;

	if (!pointerUpdFifo.empty())
	{
		pointerUpdFifo.read(upd);
		ptr_table[upd.qpn] = upd.entry;
		if (pt_lockedQP == upd.qpn)
		{
			// clear up lock
			pt_isLocked = false;
		}
	}
	else if (!pointerReqFifo.empty() && !pt_wait)
	{
		pointerReqFifo.read(pt_req);
		if (pt_req.lock && pt_isLocked)
		{
			// another lock queing up, waiting for an upd to clear prev lock
			pt_wait = true;
		}
		else
		{
			pointerRspFifo.write(ptr_table[pt_req.qpn]);
			if (pt_req.lock)
			{
				// lock is claim, can only read, cannot write
				pt_isLocked = true;
				pt_lockedQP = pt_req.qpn;
			}
		}
	}
	else if (pt_wait && !pt_isLocked)
	{
		// prev lock cleared
		pointerRspFifo.write(ptr_table[pt_req.qpn]);
		pt_isLocked = true;
		pt_lockedQP = pt_req.qpn;
		pt_wait = false;
	}
}

template <int INSTID = 0>
void retrans_meta_table(stream<retransMetaReq>&		meta_upd_req,
						stream<retransMetaEntry>&		meta_rsp)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

	static retransMetaEntry meta_table[META_TABLE_SIZE];
#if defined( __VITIS_HLS__)
	#pragma HLS bind_storage variable=meta_table type=RAM_T2P impl=BRAM
#else
	#pragma HLS RESOURCE variable=meta_table core=RAM_T2P_BRAM
#endif
	#pragma HLS DEPENDENCE variable=meta_table inter false

	retransMetaReq req;

    if (!meta_upd_req.empty())
    {
        meta_upd_req.read(req);
        if (req.write)
        {
            meta_table[req.idx] = req.entry;
        }
        else if (req.append)
        {
            meta_table[req.idx].next = req.entry.next;
            meta_table[req.idx].isTail = false;
        }
        else
        {
            meta_rsp.write(meta_table[req.idx]);
        }
    }
}

template <int INSTID = 0>
void process_retransmissions(
	stream<retransUpdate>&	        rx2retrans_upd,
    stream<retransRdInit>&          retrans2rx_init,
	stream<retransmission>&         rx2retrans_req,
	stream<retransmission>&         timer2retrans_req,
	stream<retransEntry>&	        tx2retrans_insertRequest,
	stream<ap_uint<1> >&	        tx2retrans_fence,
	stream<pointerReq>&				pointerReqFifo,
	stream<pointerUpdate>&			pointerUpdFifo,
	stream<retransPointerEntry>& 	pointerRspFifo, //TODO reorder
	stream<retransMetaReq>&			metaReqFifo,
	stream<retransMetaEntry>&		metaRspFifo,
	stream<ap_uint<16> >&			freeListFifo,
	stream<ap_uint<16> >&			releaseFifo,
	stream<retransEvent>&			retrans2event,
	stream<ackMeta>&				retrans2ack_meta
) {
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

	enum retransStateType {MAIN, INSERT_0, INSERT_1, UPDATE_0, UPDATE_1, RETRANS_0, RETRANS_1, RETRANS_2, TIMER_RETRANS_0, REPLAY};
	static retransStateType rt_state = MAIN;
	static retransUpdate update;
	static ap_uint<16> curr;
	static ap_uint<16> newMetaIdx;
	static retransEntry insert;
	static retransmission retrans;
	static retransMetaEntry meta; //TODO register needed??
	static retransPointerEntry ptrMeta;
	// last implied NAK (qpn, psn of the READ resent), so that the responses
	// and ACKs still in flight behind a lost READ response resend it once
	static bool impliedValid = false;
	static ap_uint<16> impliedQpn;
	static ap_uint<24> impliedPsn;
	// A replay sends one request after the other into retrans2event. When that
	// is full (TX busy), the next request waits in replayMeta and the updates
	// are served meanwhile: RX waits for their READ response verdicts, so a
	// replay waiting for TX must not stop RX (on a link that holds TX until
	// the far end's RX is ready, both ends would wait for each other)
	static bool replaying = false;
	static retransMetaEntry replayMeta;
	// A NAK means the responder dropped everything from its PSN on, so the
	// replay has to send every request issued so far. Those still on their
	// way through TX are not in the table yet, so the replay does not start at
	// once: a fence goes to local_req_handler, which stops issuing requests and
	// passes it on behind the last one issued. The fence comes back here after
	// that request's entry (fencePending until then); the replay of the NAK
	// then finds every request issued and, once it is done, a release lets
	// local_req_handler go on (fenced until then).
	static bool fencePending = false;
	static bool fenced = false;
	static bool fenceSent = false;

	switch (rt_state)
	{
	case MAIN:
		if (fencePending && !fenceSent && !retrans2event.full())
		{
			// the fence for a NAK just taken
			retrans2event.write(retransEvent(RT_FENCE));
			fenceSent = true;
		}
		else if (fenced && !retrans2event.full())
		{
			// the replay of the NAK is done
			retrans2event.write(retransEvent(RT_RELEASE));
			fenced = false;
		}
		else if (!rx2retrans_upd.empty())
		{
			rx2retrans_upd.read(update);
			pointerReqFifo.write(pointerReq(update.qpn, true)); // enquire whether we have previous req for this qpn
			rt_state = UPDATE_0;
			std::cout << std::hex << "[PROCESS RETRANSMISSION " << INSTID << "]: updating " << update.latest_acked_req << std::endl;
		}
		else if (!fencePending && !fenced && !rx2retrans_req.empty())
		{
			rx2retrans_req.read(retrans);
			std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: RX Retransmit triggered!! fence first" << std::endl;
			fencePending = true;
			fenceSent = false;
		}
		else if (!fencePending && !fenced && !timer2retrans_req.empty())
		{
			std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: TIMER Retransmit triggered!!" << std::endl;
			timer2retrans_req.read(retrans);
			// Uses always head psn
			pointerReqFifo.write(pointerReq(retrans.qpn)); 		// enquire whether we have previous req for this qpn
			rt_state = TIMER_RETRANS_0;
		}
		else if (!tx2retrans_insertRequest.empty() && !freeListFifo.empty())
		{
			newMetaIdx = freeListFifo.read();					// check whether we still have place to insert into `retrans meta table`
			tx2retrans_insertRequest.read(insert);
			pointerReqFifo.write(pointerReq(insert.qpn, true));	// enquire whether we have previous req for this qpn
			rt_state = INSERT_0;
			std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: inserting new meta, psn " << std::hex << insert.psn << ", occupying pointer " << newMetaIdx << std::endl;
		}
		else if (fenceSent && !tx2retrans_fence.empty() && tx2retrans_insertRequest.empty())
		{
			// every request issued before the fence is in the table: replay the NAK
			tx2retrans_fence.read();
			fencePending = false;
			fenced = true;
			std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: fence back, retransmitting qpn " << retrans.qpn << ", psn " << retrans.psn << std::endl;
			pointerReqFifo.write(pointerReq(retrans.qpn)); 		// enquire whether we have previous req for this qpn
			rt_state = RETRANS_0;
		}
		break;
	case INSERT_0:
		if (!pointerRspFifo.empty())
		{
			pointerRspFifo.read(ptrMeta);
			if (!ptrMeta.valid)
			{
				// First request for this qpn, write into both `Retrans Pointer Table`, `Retrans Meta Table`
				ptrMeta.valid = true;
				ptrMeta.head = newMetaIdx;
				ptrMeta.tail = newMetaIdx;
				metaReqFifo.write(retransMetaReq(newMetaIdx, retransMetaEntry(insert)));
				pointerUpdFifo.write(pointerUpdate(insert.qpn, ptrMeta));
				rt_state = MAIN;
				std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: inserting new entry at qpn " << insert.qpn << ", last " << insert.lst << std::endl;
			}
			else
			{
				// Update the existing "tail" entry in `Retrans Meta Table` with next=newMetaIdx
				metaReqFifo.write(retransMetaReq(ptrMeta.tail, newMetaIdx));
				// Update the tail pointer to the next index in `Retrans Meta Table`
				ptrMeta.tail = newMetaIdx;
				rt_state = INSERT_1;
				std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: appending entry at qpn " << insert.qpn << std::endl;
			}
		}
		break;
	case INSERT_1:
		// Add new entry into `Retrans Meta Table`
		metaReqFifo.write(retransMetaReq(newMetaIdx, retransMetaEntry(insert)));
		// updates `Retrans Pointer Table` with new "tail"
		pointerUpdFifo.write(pointerUpdate(insert.qpn, ptrMeta));
		rt_state = MAIN;
		break;
	case UPDATE_0:
		if (!pointerRspFifo.empty())
		{
			pointerRspFifo.read(ptrMeta);
			if (ptrMeta.valid)
			{
				// Enquire the first uncleared index (head) in `Retrans Meta Table`
				metaReqFifo.write(retransMetaReq(ptrMeta.head));
				curr = ptrMeta.head;
				rt_state = UPDATE_1;
			}
			else
			{
				// Nothing outstanding, e.g. a duplicate ACK. Release lock
				std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_0 nothing outstanding" << std::endl;
				pointerUpdFifo.write(pointerUpdate(update.qpn, ptrMeta));
				if (update.op_code != RC_ACK)
				{
					// a READ response nobody waits for
					retrans2rx_init.write(retransRdInit());
				}
				rt_state = replaying ? REPLAY : MAIN;
			}
		}
		break;
	case UPDATE_1:
		// ACKs are cumulative: an ACK releases every write and send request up to
		// and including its PSN, a read response every one before its PSN. Each
		// released request completes once on retrans2ack_meta, so a lost,
		// coalesced or duplicate ACK cannot shift the completion count.
		if (!metaRspFifo.empty())
		{
			metaRspFifo.read(meta);

			bool isReadResp = update.op_code != RC_ACK;
			ap_uint<24> releaseBefore = isReadResp ? update.latest_acked_req : ap_uint<24>(update.latest_acked_req + 1);

			if (meta.valid && meta.opCode != RC_RDMA_READ_REQUEST && psn_before(meta.psn, releaseBefore))
			{
				// The completion names the request's window slot, so rdma_flow can
				// free every slot up to it even if an earlier completion went missing
				retrans2ack_meta.write(ackMeta(RC_ACK, update.qpn, meta.host,
					meta.host ? meta.localAddr(51,48) : 0, meta.host ? meta.localAddr(53,52) : 0, meta.lst, meta.offs));
				std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_1 ack update, psn " << meta.psn << std::endl;

				// Move index
				ptrMeta.head = meta.next;
				ptrMeta.valid = !meta.isTail;

				// Clear free list
				releaseFifo.write(curr);
				curr = meta.next;

				if (meta.isTail)
				{
					// update the lock
					pointerUpdFifo.write(pointerUpdate(update.qpn, ptrMeta));
					if (isReadResp)
					{
						// a READ response nobody waits for
						retrans2rx_init.write(retransRdInit());
					}
					rt_state = replaying ? REPLAY : MAIN;
				}
				else
				{
					// check the next request
					metaReqFifo.write(retransMetaReq(meta.next));
				}
			}
			else
			{
				// A READ is answered in PSN order: meta.psn is the PSN of its next
				// response packet. Only that packet is taken. A later response, or
				// an ACK of a later request, means a response of this READ was
				// lost (implied NAK): the packet is dropped, as the responses of
				// later READs would land at this READ's address, and everything
				// from this READ on is sent again
				bool isRead = meta.valid && meta.opCode == RC_RDMA_READ_REQUEST;
				if (isRead && isReadResp && meta.psn == update.latest_acked_req)
				{
					retrans2rx_init.write(retransRdInit(meta.localAddr, meta.lst, meta.host));
					std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_1 read response psn " << meta.psn << ", laddr " << meta.localAddr << ", last " << meta.lst << std::endl;

					if (update.op_code == RC_RDMA_READ_RESP_FIRST || update.op_code == RC_RDMA_READ_RESP_MIDDLE)
					{
						// Packet update
						meta.localAddr += PMTU;
						meta.remoteAddr += PMTU;
						meta.length -= PMTU;
						meta.psn += 1;
						// Update meta table
						metaReqFifo.write(retransMetaReq(ptrMeta.head, retransMetaEntry(meta)));

						std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_1 packet update, psn " << meta.psn << ", laddr " << meta.localAddr << ", raddr " << meta.remoteAddr << ", len " << meta.length << std::endl;
					}
					else
					{
						// Move index
						ptrMeta.head = meta.next;
						ptrMeta.valid = !meta.isTail;

						// Clear free list
						releaseFifo.write(curr);

						std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_1 read update, psn " << meta.psn << std::endl;
					}
					// update the lock
					pointerUpdFifo.write(pointerUpdate(update.qpn, ptrMeta));
					rt_state = replaying ? REPLAY : MAIN;
				}
				else
				{
					if (isReadResp)
					{
						retrans2rx_init.write(retransRdInit());
						std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state UPDATE_1 dropping read response psn " << update.latest_acked_req << std::endl;
					}
					// update the lock
					pointerUpdFifo.write(pointerUpdate(update.qpn, ptrMeta));
					rt_state = replaying ? REPLAY : MAIN;

					// (not while another replay waits: the timer covers that case)
					if (!replaying && !fencePending && !fenced && isRead && psn_before(meta.psn, releaseBefore) &&
						!(impliedValid && impliedQpn == update.qpn && impliedPsn == meta.psn))
					{
						std::cout << std::hex << "[PROCESS RETRANSMISSION " << INSTID << "]: implied NAK, retransmitting from read psn " << meta.psn << std::endl;
						impliedValid = true;
						impliedQpn = update.qpn;
						impliedPsn = meta.psn;
						retrans.qpn = update.qpn;
						replayMeta = meta;
						replaying = true;
						rt_state = REPLAY;
					}
				}
			}
		}
		break;
	case RETRANS_0:
		if (!pointerRspFifo.empty())
		{
			std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: NAK, retransmitting qpn " << retrans.qpn << std::endl;
			pointerRspFifo.read(ptrMeta);
			rt_state = MAIN;
			if (ptrMeta.valid)
			{
				// Enquire the first uncleared index (head) in `Retrans Meta Table`
				metaReqFifo.write(retransMetaReq(ptrMeta.head));
				curr = ptrMeta.head;
				rt_state = RETRANS_1;
			}
		}
		break;
	case RETRANS_1:
		// loop until we get the psn "head" for retransmission
		if (!metaRspFifo.empty())
		{
			metaRspFifo.read(meta);
			rt_state = MAIN;
			if (meta.valid)
			{
				// check if we should start retransmitting
				if (meta.psn == retrans.psn)
				{
					replayMeta = meta;
					replaying = true;
					rt_state = REPLAY;
				}
				else if (!meta.isTail)
				{
					// keep traversing
					metaReqFifo.write(retransMetaReq(meta.next));
					rt_state = RETRANS_1;
				}
				else
				{
					// requested retransmission psn not stored, it is already ACKed
					std::cout << "[PROCESS RETRANSMISSION " << INSTID << "]: state RETRANS_1 trying to retransmit psn that is ACKed" << std::endl;
				}
			}
		}
		break;
	case RETRANS_2:
		// Retransmit everything until reach tail
		if (!metaRspFifo.empty())
		{
			metaRspFifo.read(replayMeta);
			replaying = replayMeta.valid;
			rt_state = replayMeta.valid ? REPLAY : MAIN;
		}
		break;
	case REPLAY:
		if (!retrans2event.full())
		{
			std::cout << std::hex << "[PROCESS RETRANSMISSION " << INSTID << "]: retransmitting psn " << replayMeta.psn << std::endl;
			retrans2event.write(retransEvent(replayMeta.opCode, retrans.qpn, replayMeta.localAddr, replayMeta.remoteAddr,
				replayMeta.length, replayMeta.psn, replayMeta.lst, replayMeta.offs));
			if (!replayMeta.isTail)
			{
				// keep retransmitting
				metaReqFifo.write(retransMetaReq(replayMeta.next));
				rt_state = RETRANS_2;
			}
			else
			{
				replaying = false;
				rt_state = MAIN;
			}
		}
		else if (!rx2retrans_upd.empty())
		{
			// TX busy: serve an update meanwhile (it may release entries the
			// replay still visits, which then go out once more: harmless, as
			// no new entry can take their place before the replay ends)
			rx2retrans_upd.read(update);
			pointerReqFifo.write(pointerReq(update.qpn, true));
			rt_state = UPDATE_0;
		}
		break;
	case TIMER_RETRANS_0:
		if (!pointerRspFifo.empty())
		{
			std::cout << std::hex << "[PROCESS RETRANSMISSION " << INSTID << "]: timed out, retransmitting qpn " << retrans.qpn << std::endl;
			pointerRspFifo.read(ptrMeta);
			// the resent READ may be lost again: allow another implied NAK
			impliedValid = false;
			if (ptrMeta.valid)
			{
				// Get continuous stream of meta entries
				metaReqFifo.write(retransMetaReq(ptrMeta.head));
				rt_state = RETRANS_2;
			}
			else
			{
				rt_state = MAIN;
			}
		}
		break;
	} // switch
}

template <int INSTID = 0>
void freelist_handler(	stream<ap_uint<16> >& rt_releaseFifo,
						stream<ap_uint<16> >& rt_freeListFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

	static ap_uint<16> freeListCounter = 0;
	#pragma HLS reset variable=freeListCounter

	if (!rt_releaseFifo.empty())
	{
		rt_freeListFifo.write(rt_releaseFifo.read());
	}
	// for initialistion to load all pointers into the FIFO
	else if (freeListCounter < META_TABLE_SIZE && !rt_freeListFifo.full())
	{
		rt_freeListFifo.write(freeListCounter);
		freeListCounter++;
	}
}

template <int INSTID = 0>
void retransmitter(	
	stream<retransUpdate>&	rx2retrans_upd,
    stream<retransRdInit>&  retrans2rx_init,
	stream<retransmission>& rx2retrans_req,
	stream<retransmission>& timer2retrans_req,
	stream<retransEntry>&	tx2retrans_insertRequest,
	stream<ap_uint<1> >&	tx2retrans_fence,
	stream<retransEvent>&	retrans2event,
	stream<ackMeta>&		retrans2ack_meta
) {
//#pragma HLS DATAFLOW
//#pragma HLS INTERFACE ap_ctrl_none register port=return
#pragma HLS INLINE

	static stream<pointerReq>				rt_pointerReqFifo("rt_pointerReqFifo");
	static stream<pointerUpdate>			rt_pointerUpdFifo("rt_pointerUpdFifo");
	static stream<retransPointerEntry> 		rt_pointerRspFifo("rt_pointerRspFifo"); //TODO reorder
	#pragma HLS STREAM depth=2 variable=rt_pointerReqFifo
	#pragma HLS STREAM depth=2 variable=rt_pointerUpdFifo
	#pragma HLS STREAM depth=2 variable=rt_pointerRspFifo

	static stream<retransMetaReq>				rt_metaReqFifo("rt_metaReqFifo");
	static stream<retransMetaEntry>			rt_metaRspFifo("rt_metaRspFifo");
	#pragma HLS STREAM depth=2 variable=rt_metaReqFifo
	#pragma HLS STREAM depth=2 variable=rt_metaRspFifo

	static stream<ap_uint<16> > rt_freeListFifo("rt_freeListFifo");
	#pragma HLS STREAM depth=META_TABLE_SIZE variable=rt_freeListFifo
	static stream<ap_uint<16> > rt_releaseFifo("rt_releaseFifo");
	#pragma HLS STREAM depth=2 variable=rt_releaseFifo

	freelist_handler<INSTID>(rt_releaseFifo, rt_freeListFifo);

	retrans_pointer_table<INSTID>(rt_pointerReqFifo, rt_pointerUpdFifo, rt_pointerRspFifo);

	retrans_meta_table<INSTID>( rt_metaReqFifo,
						rt_metaRspFifo);

	process_retransmissions<INSTID>(
		rx2retrans_upd,
        retrans2rx_init,
		rx2retrans_req,
		timer2retrans_req,
		tx2retrans_insertRequest,
		tx2retrans_fence,
		rt_pointerReqFifo,
		rt_pointerUpdFifo,
		rt_pointerRspFifo,
		rt_metaReqFifo,
		rt_metaRspFifo,
		rt_freeListFifo,
		rt_releaseFifo,
		retrans2event,
		retrans2ack_meta
	);
}
