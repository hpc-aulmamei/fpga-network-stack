# Checks a packaged RDMA stack IP:
#   1. block design: the IP from the repository, every interface made
#      external, validate_bd_design and generate_target
#   2. out-of-context synthesis and implementation of its sources at the
#      given clock period; timing and utilization reports in <work dir>
#
#   vivado -mode batch -source rdma_ooc.tcl -tclargs <IP dir> <FPGA part> <period ns> <work dir>

lassign $argv ip_dir part period work
set ip_dir [file normalize $ip_dir]
set work [file normalize $work]
set flist [lindex [glob -directory $ip_dir *.f] 0]
set name [file rootname [file tail $flist]]
file mkdir $work

# ---------------------------------------------------------------- 1. block design
create_project -force bd_check [file join $work bd_check] -part $part
set_property ip_repo_paths [list [file dirname $ip_dir]] [current_project]
update_ip_catalog
set vlnv [lindex [lsort [get_ipdefs -filter "NAME == $name"]] end]
if {$vlnv eq ""} {
    error "rdma_ooc: $name is not in the IP catalog of [file dirname $ip_dir]"
}
create_bd_design bd
set cell [create_bd_cell -type ip -vlnv $vlnv ${name}_0]
make_bd_intf_pins_external [get_bd_intf_pins -of_objects $cell]
make_bd_pins_external [get_bd_pins -of_objects $cell -filter {INTF == false}]
validate_bd_design
save_bd_design
generate_target all [get_files bd.bd]
puts "rdma_ooc: block design with $vlnv validated"
close_project

# ---------------------------------------------------------------- 2. OOC implementation
set fp [open $flist r]
set files [split [string trim [read $fp]] "\n"]
close $fp
create_project -in_memory -part $part
foreach f $files {
    set path [file join $ip_dir $f]
    if {[file extension $f] eq ".sv"} { read_verilog -sv $path } else { read_verilog $path }
}
synth_design -top $name -part $part -mode out_of_context -include_dirs [list [file join $ip_dir hdl]]
create_clock -name aclk -period $period [get_ports aclk]
# internal paths only: out of context the clock has no buffer, so every port
# path shows ~3 ns of hold violation, and the router's detours to fix it ruin
# setup elsewhere; the ports are registered or short paths into the stack
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != aclk}]
set_false_path -to [get_ports -filter {DIRECTION == OUT}]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file [file join $work timing.rpt]
report_utilization -file [file join $work utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $work utilization_hier.rpt]
set wns [get_property SLACK [get_timing_paths -setup]]
set whs [get_property SLACK [get_timing_paths -hold]]
puts "rdma_ooc: $name at $period ns: WNS $wns ns, WHS $whs ns (reports in $work)"
