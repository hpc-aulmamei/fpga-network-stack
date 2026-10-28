#!/bin/bash
# Builds the network HLS IPs of the V80 200G RoCE node (slash-roce) at
# 1024 bits for the Alveo V80 into an IP repository.
#
#   v80/build_ips.sh <build dir> [jobs]
#
# Output: <build dir>/iprepo/{rocev2,ip_handler,mac_ip_encode,
# arp_server_subnet,icmp_server}. Needs Vitis 2025.1 (vitis-run) on PATH or
# VITIS_HLS_ROOT; FPGA_PART, DATA_WIDTH and CLOCK_PERIOD can be overridden
# from the environment.
set -eo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
build=${1:?usage: build_ips.sh <build dir> [jobs]}
jobs=${2:-5}
mkdir -p "$build"
build=$(cd "$build" && pwd)

if ! command -v vitis-run >/dev/null && [ -z "$VITIS_HLS_ROOT" ]; then
    source /nfs/amd/2025.1/Vitis/settings64.sh
fi

export IPREPO_DIR=$build/iprepo
cmake -S "$here" -B "$build/cmake" \
    -DFPGA_PART="${FPGA_PART:-xcv80-lsva4737-2MHP-e-S}" \
    -DDATA_WIDTH="${DATA_WIDTH:-128}" \
    -DCLOCK_PERIOD="${CLOCK_PERIOD:-4}" \
    -DCLOCK_UNCERTAINTY="${CLOCK_UNCERTAINTY:-}" \
    -DEN_RDMA=1 -DEN_TCP=0 \
    -DIPREPO_DIR="$IPREPO_DIR"

targets=""
for ip in rocev2 ip_handler mac_ip_encode arp_server_subnet icmp_server; do
    targets="$targets services.$ip"
done
# HLS projects from an earlier run: export_design does not clear the solution
# directory, so an IP would mix old and new RTL files
for ip in $targets; do
    rm -rf "$build/cmake/hls/${ip#services.}/${ip#services.}_prj"
done
make -C "$build/cmake" -j"$jobs" $targets
ls "$IPREPO_DIR"
