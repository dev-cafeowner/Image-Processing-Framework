# New project only: stage2 hardware/ELF/archive remain immutable.
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_video30_stage3]
if {[file exists [file join $out qr_video30_stage3.xpr]]} {
    open_project [file join $out qr_video30_stage3.xpr]
} else {
    create_project qr_video30_stage3 $out -part xc7z020clg400-1
    set_property ip_repo_paths [list [file join $root hardware ip_repo custom] [file join $root hardware ip_repo runtime] [file join $root Vivado deps digilent-vivado-library ip] [file join $root Vivado deps digilent-vivado-library if]] [current_project]
    set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
    update_ip_catalog
    foreach path {hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v hardware/rtl/video/video_preview_overlay.v hardware/rtl/camera/ov7670_camera_clock.v hardware/rtl/camera/ov7670_pclk_rx.v hardware/rtl/camera/ov7670_source_sync_axis.v} {
        add_files [file join $root $path]
    }
}
if {[llength [get_files -quiet */qr_ip1_bd.bd]] == 0} {
    # Vivado requires imported sub-design sources outside the project tree.
    set seed_dir [file join $root Vivado video30_stage3_seed vivado]
    file mkdir $seed_dir
    file copy -force [file join $root hardware vivado baselines qr_video30_stage2.bd] [file join $seed_dir qr_ip1_bd.bd]
    import_files [file join $seed_dir qr_ip1_bd.bd]
}
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
if {[get_property TYPE [get_bd_cells ov7670_axis_0]] != "module"} {
    delete_bd_objs [get_bd_cells ov7670_axis_0]
    create_bd_cell -type module -reference ov7670_source_sync_axis ov7670_axis_0
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins ov7670_axis_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins ov7670_axis_0/m_axis] [get_bd_intf_pins axis_broadcaster_0/S_AXIS]
    foreach signal {data href vsync pclk xclk} {
        connect_bd_net [get_bd_ports cam_${signal}_0] [get_bd_pins ov7670_axis_0/cam_$signal]
    }
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins ov7670_axis_0/aclk]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK1] [get_bd_pins ov7670_axis_0/refclk100]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins ov7670_axis_0/aresetn]
    assign_bd_address -offset 0x40010000 -range 64K -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs ov7670_axis_0/s_axi/reg0]
}
# Replacing an upstream source can reset the converter's inferred defaults.
# Pin the existing RGB565 -> RGB888 expansion rather than allowing passthrough.
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {3} \
    CONFIG.TDATA_REMAP {tdata[15:11],tdata[15:13],tdata[10:5],tdata[10:9],tdata[4:0],tdata[4:2]} \
    CONFIG.TSTRB_REMAP {1'b1,tstrb[1:0]}] [get_bd_cells axis_subset_converter_rgb565]
validate_bd_design
if {[get_property CONFIG.M_TDATA_NUM_BYTES [get_bd_cells axis_subset_converter_rgb565]] != 3} {error "RGB888 expansion changed"}
save_bd_design
write_bd_tcl -force [file join $out design.tcl]
generate_target all $bd
puts [exec pwsh.exe -NoProfile -File [file join $root tools verify_video30_stage3.ps1]]
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top qr_ip1_bd_wrapper [current_fileset]
if {[llength [get_files -quiet *zybo_z7_20_ov7670_stage3.xdc]] == 0} {
    add_files -fileset constrs_1 [file join $root hardware constraints zybo_z7_20_ov7670_stage3.xdc]
}
set_property PROCESSING_ORDER LATE [get_files *zybo_z7_20_ov7670_stage3.xdc]
update_compile_order -fileset sources_1
if {[get_property PROGRESS [get_runs synth_1]] == "100%"} {reset_runs synth_1}
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
set skew_file [open [file join $out bus_skew.rpt] r]
set skew_text [read $skew_file]
close $skew_file
if {[string first "VIOLATED" $skew_text]>=0} {error "CDC bus skew failed: do not deploy"}
set camera_samples [get_cells -hier -filter {NAME =~ *ov7670_axis_0/inst/receiver/pin_sample_reg* && REF_NAME == FDRE}]
if {[llength $camera_samples] != 10} {error "Expected ten camera pin input registers"}
foreach cell $camera_samples {
    if {![string match "ILOGIC*" [get_property LOC $cell]]} {error "Camera input register not in IOB: $cell"}
}
report_io -file [file join $out io.rpt]
report_clocks -file [file join $out clocks.rpt]
report_timing -from [get_ports {cam_data_0[*] cam_href_0 cam_vsync_0}] -max_paths 20 -delay_type min_max -file [file join $out camera_input_timing.rpt]
if {abs([get_property PERIOD [get_clocks clk_fpga_0]] - 16.0) > 0.01 ||
    abs([get_property PERIOD [get_clocks cam_xclk_out]] - 41.6667) > 0.01} {error "Unexpected clocks"}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Timing failed: do not deploy"}
write_hw_platform -fixed -include_bit -force -file [file join $out qr_video30_stage3.xsa]
file copy -force [file join $out qr_video30_stage3.runs impl_1 qr_ip1_bd_wrapper.bit] [file join $out qr_video30_stage3.bit]
puts "VIDEO30_STAGE3_HARDWARE_PASS"
close_project
exit
