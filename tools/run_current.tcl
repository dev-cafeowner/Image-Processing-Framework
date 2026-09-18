# Current qualified QR application. Historical runners keep their old defaults.
# Requires the existing local build layout; RAM/JTAG only, no flash or SD.
if {$argc != 0} {error "Usage: xsct tools/run_current.tcl"}
set root [file dirname [file dirname [file normalize [info script]]]]
set argv [list [file join $root Vitis_video30_stage4 fallback_fast Qr_barcode_working_ver0_app.elf]]
set argc 1
source [file join $root tools run_frame_pingpong.tcl]
