#!/usr/bin/env python3
"""Collects the sources of one RDMA stack variant into a single directory.

    rdma_sources.py --name rdma_200 --data-bits 1024 --rtl <repo>/rtl \
                    --hls-iprepo <dir with rocev2/, ip_handler/, ...> --out <dir>

Writes <out>/hdl/ (the RTL of rtl/ and the Verilog of the HLS IPs) and
<out>/<name>.f (the files in compile order, relative to <out>).

Every module and package gets the prefix "<name>_" and the top level
rdma_stack becomes <name>, so rdma_100 and rdma_200 (or another copy of the
same RTL) can sit in one design. The RTL instantiates the HLS IPs by their IP
module names (<ip>_ip, as with create_ip); here those become the HLS top
modules (<ip>_top) directly, so the result needs no IP of its own.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

RTL = [
    "roce_pkg.sv", "icrc_crc32_pkg.sv",
    "small_fifo.sv", "axis_skid.sv", "axis_pkt_merge.sv", "axis_width.sv", "rx_fcs_filter.sv",
    "icrc_core.sv", "roce_tx_trim.sv", "roce_ack_pacer.sv", "roce_flow.sv", "roce_payload.sv",
    "roce_retrans_mem.sv", "roce_engine.sv", "eth_roce_stack.sv", "rdma_ctrl.sv", "rdma_stack.sv",
]
HLS_IPS = ["rocev2", "ip_handler", "mac_ip_encode", "arp_server_subnet", "icmp_server"]
TOP = "rdma_stack"

DECL = re.compile(r"^\s*(?:module|package|interface)\s+(?:automatic\s+|static\s+)?(\w+)", re.M)


def tdata_width(top_v, port):
    m = re.search(r"(?:input|output)\s+(?:wire\s+)?\[(\d+):0\]\s*" + port + r"\s*;", top_v)
    return int(m.group(1)) + 1 if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=True)
    ap.add_argument("--data-bits", type=int, required=True, choices=[512, 1024])
    ap.add_argument("--rtl", type=Path, required=True)
    ap.add_argument("--hls-iprepo", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    files = {}                                  # output name -> text, in compile order
    for f in RTL:
        files[f] = (args.rtl / f).read_text()
    for ip in HLS_IPS:
        vdir = args.hls_iprepo / ip / "hdl" / "verilog"
        if not vdir.is_dir():
            sys.exit(f"rdma_sources: no HLS IP {ip} in {args.hls_iprepo}")
        for p in sorted(vdir.iterdir()):
            if p.suffix in (".v", ".vh"):
                if p.name in files:
                    sys.exit(f"rdma_sources: two files named {p.name}")
                files[p.name] = p.read_text()

    # the HLS IPs must have the stack's width (icmp_server is always 64 bits)
    for ip, port in [("rocev2", "s_axis_rx_data_TDATA"), ("ip_handler", "s_axis_raw_TDATA"),
                     ("mac_ip_encode", "s_axis_ip_TDATA"), ("arp_server_subnet", "s_axis_TDATA")]:
        w = tdata_width(files[f"{ip}_top.v"], port)
        if w != args.data_bits:
            sys.exit(f"rdma_sources: {ip} was built at {w} bits, not {args.data_bits}")

    names = {}
    for f, text in files.items():
        for n in DECL.findall(text):
            if n in names:
                sys.exit(f"rdma_sources: {n} declared in {names[n]} and {f}")
            names[n] = f
    rename = {n: f"{args.name}_{n}" for n in names}
    rename[TOP] = args.name
    for ip in HLS_IPS:
        rename[f"{ip}_ip"] = f"{args.name}_{ip}_top"
    word = re.compile(r"\b(" + "|".join(sorted(map(re.escape, rename), key=len, reverse=True)) + r")\b")

    hdl = args.out / "hdl"
    if hdl.exists():
        shutil.rmtree(hdl)
    hdl.mkdir(parents=True)
    order = []
    for f, text in files.items():
        text = word.sub(lambda m: rename[m.group(1)], text)
        if f == f"{TOP}.sv":
            f = f"{args.name}.sv"
            text, n = re.subn(r"parameter integer DATA_BITS = \d+", f"parameter integer DATA_BITS = {args.data_bits}", text)
            if n != 1:
                sys.exit("rdma_sources: no DATA_BITS parameter in the top level")
        (hdl / f).write_text(text)
        if not f.endswith(".vh"):
            order.append(f"hdl/{f}")
    # the top level last
    order.remove(f"hdl/{args.name}.sv")
    order.append(f"hdl/{args.name}.sv")
    (args.out / f"{args.name}.f").write_text("".join(o + "\n" for o in order))
    print(f"rdma_sources: {len(order)} files, {len(rename)} names, top {args.name} ({args.data_bits} bits) in {args.out}")


if __name__ == "__main__":
    main()
