# Uses the unchanged, verified PL and the new PS application only.
set root [file dirname [file dirname [file normalize [info script]]]]
if {$argc != 0} {error "Usage: xsct run_video30_stage1.tcl"}
set argv [list [file join $root Vitis_video30_stage1 build Qr_barcode_working_ver0_app.elf]]
set argc 1
source [file join $root tools run_hardware_perf.tcl]
