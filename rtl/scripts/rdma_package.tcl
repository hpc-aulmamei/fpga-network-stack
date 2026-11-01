# Packages the sources collected by rdma_sources.py as a Vivado IP.
#
#   vivado -mode batch -source rdma_package.tcl -tclargs <IP dir> <FPGA part> <vendor> <version>
#
# <IP dir> holds <name>.f and hdl/; component.xml and xgui/ are written there,
# so the directory can be added to a project's IP repository as it is.

lassign $argv ip_dir part vendor version
set ip_dir [file normalize $ip_dir]
set flist [lindex [glob -directory $ip_dir *.f] 0]
set name [file rootname [file tail $flist]]
set fp [open $flist r]
set files [split [string trim [read $fp]] "\n"]
close $fp

# a scratch project in the working directory: the IP keeps only <IP dir>
create_project -force ${name}_package [file join [pwd] ${name}_package] -part $part
set srcs {}
foreach f $files {
    lappend srcs [file join $ip_dir $f]
}
add_files -norecurse $srcs
# simulation-only headers of the HLS IPs (deadlock detector)
foreach vh [glob -nocomplain -directory [file join $ip_dir hdl] *.vh] {
    add_files -norecurse $vh
    set_property file_type {Verilog Header} [get_files $vh]
}
set_property include_dirs [list [file join $ip_dir hdl]] [current_fileset]
set_property top $name [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_dir -vendor $vendor -library rdma -taxonomy /Networking -force
set core [ipx::current_core]

set bits [get_property value [ipx::get_user_parameters DATA_BITS -of_objects $core]]
set gbps [expr {$bits == 1024 ? 200 : 100}]
set_property name $name $core
set_property version $version $core
set_property display_name "RDMA stack ${gbps}G (RoCE v2, $bits bits)" $core
set_property description "RoCE v2 RDMA WRITE / READ over IPv4 / UDP with ARP and ICMP: fpga-network-stack HLS IPs at $bits bits and the RTL in rtl/, between an Ethernet MAC (frames without FCS) and a payload memory" $core
# UltraScale+ and Versal: the IP catalog matches the ARCHITECTURE of a part
# (virtexuplus, virtexuplusHBM, versal, ...), not its FAMILY (versalhbm)
set families {}
foreach pat {xcvu9p-* xcu55c-* xcu280-* xcvc1902-* xcv80-*} {
    foreach p [lrange [get_parts -quiet $pat] 0 0] {
        set fam [get_property ARCHITECTURE $p]
        if {[lsearch -exact $families $fam] < 0} { lappend families $fam Production }
    }
}
set_property supported_families $families $core

# the data width is fixed by the HLS IPs of this build
set_property enablement_value false [ipx::get_user_parameters DATA_BITS -of_objects $core]
set_property value_tcl_expr {} [ipx::get_user_parameters DATA_BITS -of_objects $core]

# clock and reset
set busifs {}
foreach b [ipx::get_bus_interfaces -of_objects $core] {
    if {[get_property abstraction_type_vlnv $b] in {xilinx.com:interface:axis_rtl:1.0 xilinx.com:interface:aximm_rtl:1.0}} {
        lappend busifs [get_property name $b]
    }
}
set clk [ipx::get_bus_interfaces aclk -of_objects $core]
if {$clk eq ""} {
    ipx::infer_bus_interface aclk xilinx.com:signal:clock_rtl:1.0 $core
    set clk [ipx::get_bus_interfaces aclk -of_objects $core]
}
if {[ipx::get_bus_interfaces aresetn -of_objects $core] eq ""} {
    ipx::infer_bus_interface aresetn xilinx.com:signal:reset_rtl:1.0 $core
}
set p [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clk]
if {$p eq ""} { set p [ipx::add_bus_parameter ASSOCIATED_BUSIF $clk] }
set_property value [join $busifs :] $p
set p [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clk]
if {$p eq ""} { set p [ipx::add_bus_parameter ASSOCIATED_RESET $clk] }
set_property value aresetn $p

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
puts "rdma_package: [get_property vlnv $core] in $ip_dir, interfaces on aclk: $busifs"
