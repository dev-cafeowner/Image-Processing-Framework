# Reuses the known-working bitstream byte-for-byte. No hardware build or clock
# changes. Optional ELF argument allows restoring the original application.
set root [file dirname [file dirname [file normalize [info script]]]]
set application [file join $root Vitis_sw_perf build Qr_barcode_working_ver0_app.elf]
if {$argc == 1} { set application [file normalize [lindex $argv 0]] }
if {$argc > 1} { error "Usage: xsct run_software_perf.tcl ?application.elf?" }
set bitstream [file join $root Vivado qr_probe qr_camera_fixed.bit]
set hardware [file join $root Vivado qr_probe qr_camera_fixed.xsa]
set psinit [file join $root Vitis_run Qr_barcode_working_ver0_app _ide psinit ps7_init.tcl]
foreach path [list $application $bitstream $hardware $psinit] {
    if {![file isfile $path]} { error "Missing file: $path" }
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
puts "Running $application with unchanged qr_camera_fixed.bit"
disconnect
exit
