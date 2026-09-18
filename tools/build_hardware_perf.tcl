# Separate project; never overwrite the known-working qr_camera_fixed artifacts.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_perf]
if {[file exists [file join $out qr_perf.xpr]]} {
    open_project [file join $out qr_perf.xpr]
} else {
create_project qr_perf $out -part xc7z020clg400-1
set_property ip_repo_paths [list [file join $root hardware ip_repo custom] [file join $root hardware ip_repo runtime] [file join $root Vivado deps digilent-vivado-library ip] [file join $root Vivado deps digilent-vivado-library if]] [current_project]
update_ip_catalog
add_files [file join $root hardware rtl bridge qr_rgb565_gray8_axis_tap.v]
import_files [file join $root hardware vivado qr_ip1_bd.bd]
}
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
update_ip_catalog
upgrade_bd_cells [get_bd_cells {vision_frontend_ip_0 ov7670_axis_0}]
proc reconnect_pin {source sink} {
    set dst [get_bd_pins $sink]
    foreach net [get_bd_nets -quiet -of_objects $dst] { disconnect_bd_net $net $dst }
    connect_bd_net [get_bd_pins $source] $dst
}
reconnect_pin vision_frontend_ip_0/frame_ready qr_rgb565_gray8_axis_0/frontend_frame_ready
reconnect_pin qr_runtime_exact_0/frontend_frame_release qr_rgb565_gray8_axis_0/frame_release
reconnect_pin vision_frontend_ip_0/valid_margin qr_runtime_exact_0/frontend_valid_margin
reconnect_pin vision_frontend_ip_0/fe_mode_applied qr_runtime_exact_0/fe_mode_applied
reconnect_pin qr_rgb565_gray8_axis_0/frame_drop_count qr_runtime_exact_0/frame_drop_count
set_property CONFIG.C_XCLK_DIV 2 [get_bd_cells ov7670_axis_0]
# Importing an old BD can recreate missing/renamed XCI instances with defaults.
# Pin the preview format explicitly, including byte-strobes, before propagation.
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES 3 CONFIG.TDATA_REMAP {tdata[15:11],tdata[15:13],tdata[10:5],tdata[10:9],tdata[4:0],tdata[4:2]} CONFIG.TSTRB_REMAP {1'b1,tstrb[1:0]}] [get_bd_cells axis_subset_converter_rgb565]
set_property CONFIG.CONST_WIDTH 18 [get_bd_cells xlconstant_zero18]
validate_bd_design
if {[get_property CONFIG.M_TDATA_NUM_BYTES [get_bd_cells axis_subset_converter_rgb565]] != 3} {error "Preview converter must output RGB888"}
save_bd_design
write_bd_tcl -force [file join $out qr_perf_bd.tcl]
generate_target all $bd
set wrapper [make_wrapper -files $bd -top]
add_files $wrapper
set_property top qr_ip1_bd_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $root hardware constraints zybo_z7_20_ov7670_fclk125.xdc]
set_property PROCESSING_ORDER LATE [get_files *.xdc]
update_compile_order -fileset sources_1
if {[get_property PROGRESS [get_runs synth_1]] == "100%"} {reset_runs synth_1}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {error "Implementation failed"}
open_run impl_1
if {[llength [get_clocks -quiet clk_fpga_0]] != 1 ||
    abs([get_property PERIOD [get_clocks clk_fpga_0]] - 16.0) > 0.01 ||
    [llength [get_clocks -quiet cam_xclk_out]] != 1 ||
    abs([get_property PERIOD [get_clocks cam_xclk_out]] - 32.0) > 0.01} {
    error "Missing or unexpected implemented camera/PL clocks"
}
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_cdc -file [file join $out cdc.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {error "Timing failed: do not deploy"}
write_hw_platform -fixed -include_bit -force -file [file join $out qr_perf.xsa]
file copy -force [file join $out qr_perf.runs impl_1 qr_ip1_bd_wrapper.bit] [file join $out qr_perf.bit]
puts "PERF_HARDWARE_BUILD_PASS"
close_project
exit
