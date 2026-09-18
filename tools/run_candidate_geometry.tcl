# Selected Geometry/ROI release. JTAG/RAM only, never flash or SD.
if {$argc != 0} {error "Usage: xsct tools/run_candidate_geometry.tcl"}
set root [file dirname [file dirname [file normalize [info script]]]]
set argv [list [file join $root Vitis_video30_stage4 candidate_geometry_fast Qr_barcode_working_ver0_app.elf]]
set argc 1
source [file join $root tools run_candidate_address_fix.tcl]
