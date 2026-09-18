set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_candidate_address_fix]
open_checkpoint [file join $out qr_candidate_address_fix.runs impl_1 qr_ip1_bd_wrapper_routed.dcp]
set mmcm [get_cells -hier -filter {NAME =~ *return_clock/mmcm* && REF_NAME =~ MMCME2*}]
if {[llength $mmcm]!=1} {error "Expected returned-clock MMCM"}
foreach {property expected} {CLKFBOUT_MULT_F 32.0 CLKOUT0_DIVIDE_F 32.0 CLKOUT0_PHASE 90.0} {
    if {abs([get_property $property $mmcm]-$expected)>0.001} {error "MMCM changed: $property"}
}
if {[get_property BANDWIDTH $mmcm] ne "LOW"} {error "MMCM bandwidth changed"}
set pins [get_cells -hier -filter {NAME =~ *receiver/pin_sample_reg* && REF_NAME == FDRE}]
if {[llength $pins]!=10} {error "Expected ten IOB input registers"}
foreach r $pins {if {![string match "ILOGIC*" [get_property LOC $r]]} {error "Not in IOB: $r"}}
set input_paths [get_timing_paths -from [get_ports {cam_data_0[*] cam_href_0 cam_vsync_0}] -delay_type min_max -max_paths 20]
if {[llength $input_paths]<10} {error "Missing constrained input timing paths"}
foreach p $input_paths {if {[get_property SLACK $p]<0} {error "Camera input timing failed"}}
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
if {$setup<0 || $hold<0} {error "Timing failed"}
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_timing -from [get_ports {cam_data_0[*] cam_href_0 cam_vsync_0}] -delay_type min_max -max_paths 20 -file [file join $out camera_input_timing.rpt]
puts "CANDIDATE_PHYSICAL_PASS setup=$setup hold=$hold inputs=[llength $input_paths]"
close_design
exit
