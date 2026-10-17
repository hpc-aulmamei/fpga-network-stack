#!/bin/bash
# test_rocev2_pair.sh BYTES [scenario...]: build and run the two-endpoint
# rocev2 csim (rocev2/test_rocev2_pair.cpp) with DATA_WIDTH = BYTES.
W=${1:-128}; shift
SCEN=${*:-clean sizes loss ack-loss daq window32}
H=/scratch/users/aulmamei/v80/arh-coyote/hw/services/network/hls
B=/scratch/users/aulmamei/v80/hlsbuild/pair_w$W
INC=${HLS_INCLUDE:-/nfs/amd/Vitis/2024.2/include}
mkdir -p $B
for f in $H/rocev2/rocev2_config.hpp.in $H/ipv4/ipv4_config.hpp.in $H/ipv6/ipv6_config.hpp.in $H/udp/udp_config.hpp.in; do
  sed -e "s|\${DATA_WIDTH}|$W|g; s|\${ROCE_STACK_MAX_QPS}|500|g; s|\${PMTU_BYTES}|4096|g; s|\${RETRANS_EN}|1|g" $f > $B/$(basename $f .in)
done
cat > $B/udp_inst.cpp <<EOT
// udp.cpp instantiates udp<> only in the HLS build
#include "$H/udp/udp.cpp"
template void udp<DATA_WIDTH>(hls::stream<ipMeta>&, hls::stream<net_axis<DATA_WIDTH> >&, hls::stream<ipUdpMeta>&,
    hls::stream<net_axis<DATA_WIDTH> >&, hls::stream<ipUdpMeta>&, hls::stream<net_axis<DATA_WIDTH> >&,
    hls::stream<ipMeta>&, hls::stream<net_axis<DATA_WIDTH> >&, ap_uint<128>, ap_uint<16>);
EOT
g++ -std=c++14 -O2 -w -I$INC -I$B $H/axi_utils.cpp $H/ipv4/ipv4_utils.cpp $H/ipv4/ipv4.cpp $H/ipv6/ipv6.cpp \
  $B/udp_inst.cpp $H/crc/crc.cpp $H/ib_transport_protocol/ib_utils.cpp $H/ib_transport_protocol/ib_transport_protocol.cpp \
  $H/rocev2/rocev2.cpp $H/rocev2/test_rocev2_pair.cpp -o $B/test_rocev2_pair || exit 1
fail=0
for s in $SCEN; do timeout 1800 $B/test_rocev2_pair $s 2>&1 | grep -v "HLS SIM" || fail=1; done
exit $fail
