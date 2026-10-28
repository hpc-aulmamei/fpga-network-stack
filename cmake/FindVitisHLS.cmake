# Locates the Vitis HLS front end for the per-IP CMakeLists.
#
# Sets VITIS_HLS_FOUND, VITIS_HLS_BINARY and VITIS_HLS_MODE: "vitis_hls" for
# the classic binary (-f make.tcl, up to 2024.2), "vitis-run" from 2025.1 on
# (--mode hls --tcl make.tcl). VITIS_HLS_ROOT (variable or environment) may
# point at the Vitis or Vitis_HLS installation; otherwise PATH is searched.

set(_vhls_hints)
foreach(_r "${VITIS_HLS_ROOT}" "$ENV{VITIS_HLS_ROOT}" "$ENV{XILINX_VITIS}" "$ENV{XILINX_HLS}")
    if(_r)
        list(APPEND _vhls_hints "${_r}/bin")
    endif()
endforeach()

find_program(VITIS_RUN_BINARY vitis-run HINTS ${_vhls_hints})
find_program(VITIS_HLS_CLASSIC_BINARY vitis_hls HINTS ${_vhls_hints})

if(VITIS_RUN_BINARY)
    set(VITIS_HLS_BINARY ${VITIS_RUN_BINARY})
    set(VITIS_HLS_MODE "vitis-run")
elseif(VITIS_HLS_CLASSIC_BINARY)
    set(VITIS_HLS_BINARY ${VITIS_HLS_CLASSIC_BINARY})
    set(VITIS_HLS_MODE "vitis_hls")
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(VitisHLS DEFAULT_MSG VITIS_HLS_BINARY)
set(VITIS_HLS_FOUND ${VITISHLS_FOUND})
mark_as_advanced(VITIS_RUN_BINARY VITIS_HLS_CLASSIC_BINARY)
