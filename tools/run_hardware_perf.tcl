set root [file dirname [file dirname [file normalize [info script]]]]
set application [file join $root Vitis_hw_perf build Qr_barcode_working_ver0_app.elf]
if {$argc == 1} {set application [file normalize [lindex $argv 0]]}
if {$argc > 1} {error "Usage: xsct run_hardware_perf.tcl ?application.elf?"}
set bitstream [file join $root Vivado qr_perf qr_perf.bit]
set hardware [file join $root Vivado qr_perf qr_perf.xsa]
# PS clocks, DDR and address map are unchanged. Build verification checks them.
set psinit [file join $root Vitis_run Qr_barcode_working_ver0_app _ide psinit ps7_init.tcl]
foreach path [list $application $bitstream $hardware $psinit] {
    if {![file isfile $path]} {error "Missing file: $path"}
}
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
rst
fpga -file $bitstream
loadhw $hardware
source $psinit
ps7_init
ps7_post_config
dow $application
con
puts "Running $application with qr_perf.bit"
disconnect
exit
