#!/bin/bash
# Two-node simulation of a packaged RDMA stack IP (tb_rdma_stack.sv) in xsim.
#
#   sim/rdma/run_tb.sh <IP dir> <work dir> [plusargs, e.g. +DROP=50 +N=400]
#
# <IP dir> is the output of make rdma_100 / rdma_200 (<name>.f, hdl/, and
# component.xml). Needs Vivado (xvlog, xelab, xsim) on PATH or XILINX_VIVADO.
set -eo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ip=$(cd "${1:?usage: run_tb.sh <IP dir> <work dir> [plusargs]}" && pwd)
work=${2:?usage: run_tb.sh <IP dir> <work dir> [plusargs]}
shift 2
# make rdma_<n>_sim passes plusargs in the environment
if [ $# -eq 0 ] && [ -n "$RDMA_SIM_ARGS" ]; then
    set -- $RDMA_SIM_ARGS
fi

if ! command -v xvlog >/dev/null; then
    if [ -n "$XILINX_VIVADO" ]; then
        PATH=$XILINX_VIVADO/bin:$PATH
    else
        echo "run_tb.sh: Vivado not found (PATH or XILINX_VIVADO)" >&2
        exit 1
    fi
fi
viv=$(cd "$(dirname "$(command -v xvlog)")/.." && pwd)

flist=$(ls "$ip"/*.f)
name=$(basename "$flist" .f)
bits=$(sed -n 's/.*parameter integer DATA_BITS = \([0-9]*\).*/\1/p' "$ip/hdl/$name.sv" | head -1)

mkdir -p "$work"
cd "$work"
xpm=$viv/data/ip/xpm
xvlog -sv "$xpm/xpm_cdc/hdl/xpm_cdc.sv" "$xpm/xpm_memory/hdl/xpm_memory.sv" \
    "$xpm/xpm_fifo/hdl/xpm_fifo.sv" > xvlog_xpm.log
xvlog "$viv/data/verilog/src/glbl.v" > xvlog_glbl.log
v_files=$(grep '\.v$' "$flist" | sed "s|^|$ip/|")
sv_files=$(grep '\.sv$' "$flist" | sed "s|^|$ip/|")
xvlog -i "$ip/hdl" $v_files > xvlog_v.log
# RDMA_SIM_DEFINES="ROCE_TRACE": packet and payload command trace of the stack
defs=()
for d in $RDMA_SIM_DEFINES; do defs+=(-d "$d"); done
xvlog -sv -i "$ip/hdl" -d DATA_BITS="$bits" -d RDMA_TOP="$name" "${defs[@]}" $sv_files "$here/tb_rdma_stack.sv" > xvlog_sv.log
xelab -debug off -relax -timescale 1ns/1ps -s tb tb_rdma_stack glbl > xelab.log
plus=()
for p in "$@"; do
    case "$p" in
        +SEED=*) plus+=(-sv_seed "${p#+SEED=}") ;;
        *) plus+=(-testplusarg "${p#+}") ;;
    esac
done
xsim tb -R "${plus[@]}" | tee xsim.out | grep -v "^Time resolution\|^INFO\|^ *$"
grep -q "^PASS" xsim.out
