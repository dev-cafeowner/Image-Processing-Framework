# Read-only final physical checks, including XPM Gray-bus skew and IOB packing.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_video30_stage3]
open_checkpoint [file join $out qr_video30_stage3.runs impl_1 qr_ip1_bd_wrapper_routed.dcp]
report_bus_skew -file [file join $out bus_skew_verified.rpt]
set f [open [file join $out bus_skew_verified.rpt] r]
set report [read $f]
close $f
if {[string first "VIOLATED" $report]>=0} {error "CDC bus skew violated"}
set registers [get_cells -hier -filter {NAME =~ *ov7670_axis_0/inst/receiver/pin_sample_reg* && REF_NAME == FDRE}]
if {[llength $registers] != 10} {error "Expected ten camera input registers"}
foreach r $registers {
    puts "CAMERA_INPUT_IOB $r [get_property LOC $r]"
    if {![string match "ILOGIC*" [get_property LOC $r]]} {error "Camera input outside IOB"}
}
foreach {name period} {clk_fpga_0 16.0 clk_fpga_1 10.0 cam_pclk_pin 40.0 cam_xclk_out 41.6667} {
    if {abs([get_property PERIOD [get_clocks $name]]-$period)>0.01} {error "Unexpected clock $name"}
}
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "STAGE3_TIMING setup=$setup hold=$hold"
if {$setup<0 || $hold<0} {error "Timing failed"}
puts "CAMERA_STAGE3_PHYSICAL_PASS"
close_design
exit
