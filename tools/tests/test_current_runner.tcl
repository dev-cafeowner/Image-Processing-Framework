# No board access: inspect wrapper dispatch and reject unexpected arguments.
set root [file dirname [file dirname [file dirname [file normalize [info script]]]]]
set script [file join $root tools run_current.tcl]
rename source real_source
set dispatched 0
proc source {path} {
    if {[file tail $path] eq "run_frame_pingpong.tcl"} {
        set expected [file join $::root Vitis_video30_stage4 fallback_fast Qr_barcode_working_ver0_app.elf]
        if {$::argc != 1 || [lindex $::argv 0] ne $expected} {error "Incorrect current ELF dispatch"}
        set ::dispatched 1
        return
    }
    uplevel 1 [list real_source $path]
}
set argc 0
set argv {}
source $script
if {!$dispatched} {error "Current runner did not dispatch"}
set argc 1
set argv {unexpected}
if {![catch {source $script} message] || ![string match "Usage:*" $message]} {error "Unexpected argument was accepted"}
puts "PASS: current runner selects fallback_fast and rejects arguments; no hardware access"
