# RAM/JTAG deployment only; no flash or SD writes. Optional diagnostic ELF.
set root [file dirname [file dirname [file normalize [info script]]]]
if {$argc > 1} {error "Usage: xsct run_candidate_address_fix.tcl ?application.elf?"}
set app [file join $root Vitis_video30_stage4 drive1x Qr_barcode_working_ver0_app.elf]
if {$argc == 1} {set app [file normalize [lindex $argv 0]]}
set dir [file join $root Vivado qr_candidate_address_fix]
set bit [file join $dir qr_candidate_address_fix.bit]
set xsa [file join $dir qr_candidate_address_fix.xsa]
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
if {[expr [mrd -value 0x43c30000]] != 0x50525631 || [expr [mrd -value 0x40010010]] != 0x43414d33 || [expr [mrd -value 0x4001000c]] != 0x00030000} {error "Stage4 ABI check failed"}
dow $app
con
puts "Running $app with $bit"
disconnect
exit
