# One-variable external XCLK output-buffer profile; no RTL/clock rate changes.
# Separate artifact: the qualified digital stage4 implementation is preserved.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_video30_stage4]
set prefix [file join $out qr_video30_stage4_xclk_slow4]
if {[file exists ${prefix}.bit]} {error "Variant exists; do not overwrite"}
open_checkpoint [file join $out qr_video30_stage4.runs impl_1 qr_ip1_bd_wrapper_routed.dcp]
set port [get_ports cam_xclk_0]
if {[get_property DRIVE $port]!=8 || [get_property SLEW $port] ne "FAST"} {
    error "Unexpected baseline output-buffer profile"
}
set_property DRIVE 4 $port
set_property SLEW SLOW $port
report_io -file ${prefix}_io.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file ${prefix}_timing.rpt
report_bus_skew -file ${prefix}_skew.rpt
set f [open ${prefix}_skew.rpt r]
set skew [read $f]
close $f
if {[string first "VIOLATED" $skew]>=0} {error "CDC skew failed"}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]<0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "Timing failed"}
if {abs([get_property PERIOD [get_clocks cam_xclk_out]]-41.6667)>0.01} {error "XCLK rate changed"}
write_checkpoint ${prefix}.dcp
# write_bitstream runs DRC; do not lower severity or force a failed check.
write_bitstream ${prefix}.bit
puts "STAGE4_SLOWCLK_BUILD_PASS drive=[get_property DRIVE $port] slew=[get_property SLEW $port]"
close_design
exit
