# New project and artifacts. Do not modify qr_perf or its archived baseline.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_video30_stage2]
if {[file exists [file join $out qr_video30_stage2.xpr]]} {
    open_project [file join $out qr_video30_stage2.xpr]
} else {
    create_project qr_video30_stage2 $out -part xc7z020clg400-1
    set_property ip_repo_paths [list [file join $root hardware ip_repo custom] [file join $root hardware ip_repo runtime] [file join $root Vivado deps digilent-vivado-library ip] [file join $root Vivado deps digilent-vivado-library if]] [current_project]
    update_ip_catalog
    add_files [file join $root hardware rtl bridge qr_rgb565_gray8_axis_tap.v]
    add_files [file join $root hardware rtl video video_preview_overlay.v]
    # Checked-in JSON-equivalent copy of the verified stage1 BD. Import under
    # its original filename so existing wrapper/IP instance names stay stable.
    set seed_dir [file join $out stage1_seed vivado]
    file mkdir $seed_dir
    file copy -force [file join $root hardware vivado baselines qr_perf_stage1.bd] [file join $seed_dir qr_ip1_bd.bd]
    import_files [file join $seed_dir qr_ip1_bd.bd]
}
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
update_ip_catalog
# Imported verified project already contains the exact-sync fixes and DIV=2.
if {[llength [get_bd_cells -quiet video_preview_overlay_0]] == 0} {
    create_bd_cell -type module -reference video_preview_overlay video_preview_overlay_0
    set_property CONFIG.NUM_MI 9 [get_bd_cells axi_smc]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M08_AXI] [get_bd_intf_pins video_preview_overlay_0/s_axi]
    set old_net [get_bd_intf_nets -of_objects [get_bd_intf_pins axis_subset_converter_0/M_AXIS]]
    disconnect_bd_intf_net $old_net [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
    connect_bd_intf_net [get_bd_intf_pins axis_subset_converter_0/M_AXIS] [get_bd_intf_pins video_preview_overlay_0/s_axis]
    connect_bd_intf_net [get_bd_intf_pins video_preview_overlay_0/m_axis] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins video_preview_overlay_0/aclk]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins video_preview_overlay_0/aresetn]
    assign_bd_address -offset 0x43C30000 -range 32K -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs video_preview_overlay_0/s_axi/reg0]
}
# Scalar observation overrides a bundled AXIS pin in IP Integrator. Explicitly
# include BOTH original endpoints, including the VDMA TREADY driver, so the
# monitor cannot disconnect the stream being observed. Idempotent on reruns.
foreach {signal sink} {tvalid camera_valid tready camera_ready tuser camera_sof} {
    set pins [list [get_bd_pins axis_subset_converter_rgb565/m_axis_$signal] [get_bd_pins axi_vdma_0/s_axis_s2mm_$signal] [get_bd_pins video_preview_overlay_0/$sink]]
    foreach pin $pins {
        foreach net [get_bd_nets -quiet -of_objects $pin] {disconnect_bd_net $net $pin}
    }
    connect_bd_net {*}$pins
}
validate_bd_design
if {[get_property CONFIG.C_XCLK_DIV [get_bd_cells ov7670_axis_0]] != 2} {error "Camera clock changed unexpectedly"}
save_bd_design
write_bd_tcl -force [file join $out design.tcl]
generate_target all $bd
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top qr_ip1_bd_wrapper [current_fileset]
if {[llength [get_files -quiet *zybo_z7_20_ov7670_fclk125.xdc]] == 0} {
    add_files -fileset constrs_1 [file join $root hardware constraints zybo_z7_20_ov7670_fclk125.xdc]
}
set board_constraints [get_files *zybo_z7_20_ov7670_fclk125.xdc]
if {[llength $board_constraints] != 1} {error "Board pin/timing constraints missing or ambiguous"}
set_property PROCESSING_ORDER LATE $board_constraints
update_compile_order -fileset sources_1
if {[get_property PROGRESS [get_runs synth_1]] == "100%"} {reset_runs synth_1}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {error "Implementation failed"}
open_run impl_1
if {abs([get_property PERIOD [get_clocks clk_fpga_0]] - 16.0) > 0.01 ||
    abs([get_property PERIOD [get_clocks cam_xclk_out]] - 32.0) > 0.01} {error "Unexpected clocks"}
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_cdc -file [file join $out cdc.rpt]
report_io -file [file join $out io.rpt]
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Timing failed: do not deploy"}
write_hw_platform -fixed -include_bit -force -file [file join $out qr_video30_stage2.xsa]
file copy -force [file join $out qr_video30_stage2.runs impl_1 qr_ip1_bd_wrapper.bit] [file join $out qr_video30_stage2.bit]
puts "VIDEO30_STAGE2_HARDWARE_PASS"
close_project
exit
