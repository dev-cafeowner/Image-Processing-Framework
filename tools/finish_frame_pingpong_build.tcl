# Shared implementation/qualification gates. Caller supplies root/name/out.
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {error "Implementation failed"}
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
set f [open [file join $out bus_skew.rpt] r]; set skew [read $f]; close $f
if {[string first "VIOLATED" $skew] >= 0} {error "CDC skew failed"}
set samples [get_cells -hier -filter {NAME =~ *ov7670_axis_0/inst/receiver/pin_sample_reg* && REF_NAME == FDRE}]
if {[llength $samples] != 10} {error "Expected ten camera input registers"}
foreach cell $samples {if {![string match "ILOGIC*" [get_property LOC $cell]]} {error "Camera input register not in IOB"}}
if {abs([get_property PERIOD [get_clocks clk_fpga_0]] - 16.0) > 0.01 || abs([get_property PERIOD [get_clocks cam_xclk_out]] - 41.6667) > 0.01} {error "Clocks changed"}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 || [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Timing failed; do not deploy"}
write_hw_platform -fixed -include_bit -file [file join $out ${name}.xsa]
file copy [file join $out ${name}.runs impl_1 qr_ip1_bd_wrapper.bit] [file join $out ${name}.bit]
puts "FRAME_PINGPONG_HARDWARE_PASS"
close_project
exit
