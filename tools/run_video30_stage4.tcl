set root [file dirname [file dirname [file normalize [info script]]]]
# Selected fixed-scene VGA30 profile: COM2=0 (1x). build/ is the rejected 2x diagnostic.
set application [file join $root Vitis_video30_stage4 drive1x Qr_barcode_working_ver0_app.elf]
if {$argc >= 1} {set application [file normalize [lindex $argv 0]]}
if {$argc > 2} {error "Usage: xsct run_video30_stage4.tcl ?application.elf? ?stage4_variant.bit?"}
set bitstream [file join $root Vivado qr_video30_stage4 qr_video30_stage4.bit]
if {$argc == 2} {set bitstream [file normalize [lindex $argv 1]]}
set hardware [file join $root Vivado qr_video30_stage4 qr_video30_stage4.xsa]
set psinit [file join $root Vitis_run Qr_barcode_working_ver0_app _ide psinit ps7_init.tcl]
foreach path [list $application $bitstream $hardware $psinit] {
    if {![file isfile $path]} {error "Missing file: $path"}
}
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
rst
fpga -file $bitstream
loadhw $hardware
source $psinit
ps7_init
ps7_post_config
if {[expr [mrd -value 0x43c30000]] != 0x50525631} {error "Missing PRV1 hardware"}
if {[expr [mrd -value 0x40010010]] != 0x43414d33} {error "Missing CAM3 hardware"}
if {[expr [mrd -value 0x4001000c]] != 0x00030000} {error "Stage4 clock-control ABI missing"}
dow $application
con
puts "Running $application with $bitstream"
disconnect
exit
