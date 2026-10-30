# RDMA stack IP: the HLS IPs of this repository with the RTL in rtl/,
# packaged as one Vivado IP per line rate.
#
#   make rdma_100       512 bits:  ${RDMA_IPREPO}/rdma_100
#   make rdma_200       1024 bits: ${RDMA_IPREPO}/rdma_200
#   make rdma_<n>_sim   two-node simulation of the packaged IP (xsim);
#                       plusargs from the environment, RDMA_SIM_ARGS="+DROP=50"
#   make rdma_<n>_ooc   the IP in a block design, then out-of-context
#                       synthesis and implementation at CLOCK_PERIOD
#
# Each line rate builds its HLS IPs (rocev2, ip_handler, mac_ip_encode,
# arp_server_subnet, icmp_server) in a CMake build of its own under
# ${CMAKE_BINARY_DIR}/rdma_<n>/, independent of DATA_WIDTH / EN_RDMA here, and
# again only when a source under hls/ changes. doc/rdma_stack.md describes the
# IP.

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(VIVADO_BINARY vivado HINTS ${VIVADO_ROOT}/bin $ENV{XILINX_VIVADO}/bin)
if(NOT VIVADO_BINARY)
    message(STATUS "Vivado not found: the rdma_* targets need it on PATH (or XILINX_VIVADO / VIVADO_ROOT)")
endif()

set(RDMA_IPREPO ${CMAKE_BINARY_DIR}/iprepo CACHE PATH "Output directory of the packaged RDMA stack IPs")
set(RDMA_IP_VENDOR "ethz.systems.fpga" CACHE STRING "Vendor of the packaged RDMA stack IPs")
set(RDMA_IP_VERSION "1.0" CACHE STRING "Version of the packaged RDMA stack IPs")
set(RDMA_HLS_JOBS 5 CACHE STRING "HLS IPs synthesized in parallel")

set(RDMA_HLS_IPS rocev2 ip_handler mac_ip_encode arp_server_subnet icmp_server)
file(GLOB_RECURSE RDMA_HLS_SOURCES CONFIGURE_DEPENDS
    ${CMAKE_SOURCE_DIR}/hls/*.cpp ${CMAKE_SOURCE_DIR}/hls/*.hpp ${CMAKE_SOURCE_DIR}/hls/*.in
    ${CMAKE_SOURCE_DIR}/hls/*/CMakeLists.txt)
file(GLOB RDMA_RTL_SOURCES CONFIGURE_DEPENDS
    ${CMAKE_SOURCE_DIR}/rtl/*.sv ${CMAKE_SOURCE_DIR}/rtl/scripts/*)

function(rdma_stack_ip name bits)
    math(EXPR bytes "${bits} / 8")
    set(dir ${CMAKE_BINARY_DIR}/${name})
    set(hls_repo ${dir}/hls_iprepo)
    set(ip_dir ${RDMA_IPREPO}/${name})
    set(hls_targets)
    foreach(ip ${RDMA_HLS_IPS})
        list(APPEND hls_targets services.${ip})
    endforeach()

    # a fresh HLS build each time: export_design leaves the RTL of an earlier
    # run in the solution directory, so an IP could mix old and new files
    add_custom_command(
        OUTPUT ${dir}/hls.stamp
        COMMAND ${CMAKE_COMMAND} -E rm -rf ${dir}/hls ${hls_repo}
        COMMAND ${CMAKE_COMMAND} -E env IPREPO_DIR=${hls_repo}
                ${CMAKE_COMMAND} -S ${CMAKE_SOURCE_DIR} -B ${dir}/hls -G ${CMAKE_GENERATOR}
                -DRDMA_NESTED=ON -DEN_RDMA=1 -DEN_TCP=0 -DDATA_WIDTH=${bytes}
                -DFPGA_PART=${FPGA_PART} -DCLOCK_PERIOD=${CLOCK_PERIOD}
                -DCLOCK_UNCERTAINTY=${CLOCK_UNCERTAINTY} -DIPREPO_DIR=${hls_repo}
        COMMAND ${CMAKE_COMMAND} -E env IPREPO_DIR=${hls_repo}
                ${CMAKE_COMMAND} --build ${dir}/hls --parallel ${RDMA_HLS_JOBS} --target ${hls_targets}
        COMMAND ${CMAKE_COMMAND} -E touch ${dir}/hls.stamp
        DEPENDS ${RDMA_HLS_SOURCES}
        COMMENT "${name}: HLS IPs at ${bits} bits for ${FPGA_PART}, ${CLOCK_PERIOD} ns"
        VERBATIM)

    add_custom_command(
        OUTPUT ${ip_dir}/component.xml
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/rtl/scripts/rdma_sources.py
                --name ${name} --data-bits ${bits} --rtl ${CMAKE_SOURCE_DIR}/rtl
                --hls-iprepo ${hls_repo} --out ${ip_dir}
        COMMAND ${VIVADO_BINARY} -mode batch -nojournal -log ${dir}/package.log
                -source ${CMAKE_SOURCE_DIR}/rtl/scripts/rdma_package.tcl
                -tclargs ${ip_dir} ${FPGA_PART} ${RDMA_IP_VENDOR} ${RDMA_IP_VERSION}
        DEPENDS ${dir}/hls.stamp ${RDMA_RTL_SOURCES}
        WORKING_DIRECTORY ${dir}
        COMMENT "${name}: packaging the IP in ${ip_dir}"
        VERBATIM)
    add_custom_target(${name} DEPENDS ${ip_dir}/component.xml)

    add_custom_target(${name}_sim
        COMMAND ${CMAKE_COMMAND} -E make_directory ${dir}/sim
        COMMAND ${CMAKE_SOURCE_DIR}/sim/rdma/run_tb.sh ${ip_dir} ${dir}/sim
        DEPENDS ${name}
        COMMENT "${name}: two-node simulation in ${dir}/sim"
        VERBATIM)

    add_custom_target(${name}_ooc
        COMMAND ${VIVADO_BINARY} -mode batch -nojournal -log ${dir}/ooc.log
                -source ${CMAKE_SOURCE_DIR}/rtl/scripts/rdma_ooc.tcl
                -tclargs ${ip_dir} ${FPGA_PART} ${CLOCK_PERIOD} ${dir}/ooc
        DEPENDS ${name}
        WORKING_DIRECTORY ${dir}
        COMMENT "${name}: block design check and out-of-context implementation in ${dir}/ooc"
        VERBATIM)
endfunction()

rdma_stack_ip(rdma_100 512)
rdma_stack_ip(rdma_200 1024)
