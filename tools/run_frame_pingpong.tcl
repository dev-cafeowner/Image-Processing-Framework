# QPP1-only deployment; RAM/JTAG, no flash/SD. Explicit optional test ELF.
set root [file dirname [file dirname [file normalize [info script]]]]
if {$argc > 1} {error "Usage: xsct run_frame_pingpong.tcl ?application.elf?"}
set app [file join $root Vitis_video30_stage4 frame_pingpong_seed8 Qr_barcode_working_ver0_app.elf]
if {$argc == 1} {set app [file normalize [lindex $argv 0]]}
if {![info exists hardware_name]} {set hardware_name qr_frame_pingpong}
set dir [file join $root Vivado $hardware_name]
set bit [file join $dir ${hardware_name}.bit]
set xsa [file join $dir ${hardware_name}.xsa]
set psinit [file join $root Vitis_run Qr_barcode_working_ver0_app _ide psinit ps7_init.tcl]
foreach path [list $app $bit $xsa $psinit] {if {![file isfile $path]} {error "Missing $path"}}
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
rst
fpga -file $bit
loadhw $xsa
source $psinit
ps7_init
ps7_post_config
if {[expr [mrd -value 0x43c40000]] != 0x51505031 || [expr [mrd -value 0x43c40004]] != 0x00010000 || [expr [mrd -value 0x43c4002c]] != 0x01e00280 || [expr [mrd -value 0x43c30000]] != 0x50525631 || [expr [mrd -value 0x40010010]] != 0x43414d33} {error "QPP1 / Stage4 ABI check failed"}
dow $app
con
puts "Running $app with $bit"
disconnect
exit
