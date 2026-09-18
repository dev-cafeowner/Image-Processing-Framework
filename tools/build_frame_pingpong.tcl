# Isolated QPP1 build. Qualified single-bank bit/XSA are never overwritten.
set root [file dirname [file dirname [file normalize [info script]]]]
if {![info exists name]} {set name qr_frame_pingpong}
set out [file join $root Vivado $name]
if {[file exists [file join $out ${name}.bit]]} {error "Output exists; choose a new qualified build name"}
create_project -force $name $out -part xc7z020clg400-1
set_property ip_repo_paths [list [file join $root hardware ip_repo custom] [file join $root hardware ip_repo runtime] [file join $root Vivado deps digilent-vivado-library ip] [file join $root Vivado deps digilent-vivado-library if]] [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
update_ip_catalog
foreach path {bridge/qr_rgb565_gray8_axis_tap.v bridge/qr_binary_bram_address_adapter.v bridge/qr_binary_pingpong_address.v bridge/qr_frame_pingpong.v video/video_preview_overlay.v camera/ov7670_camera_clock.v camera/ov7670_pclk_rx.v camera/ov7670_clean_sync_axis.v camera/ov7670_pclk_clean_clock.v} {add_files [file join $root hardware rtl $path]}
set seed [file join $root Vivado frame_pingpong_seed vivado]
file mkdir $seed
file copy -force [file join $root Vivado qr_candidate_address_fix qr_candidate_address_fix.srcs sources_1 bd vivado qr_ip1_bd.bd] [file join $seed qr_ip1_bd.bd]
import_files [file join $seed qr_ip1_bd.bd]
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
proc detach {path} {
    set pin [get_bd_pins $path]
    foreach net [get_bd_nets -quiet -of_objects $pin] {disconnect_bd_net $net $pin}
}
proc wire_to {source sink} {
    detach $sink
    connect_bd_net [get_bd_pins $source] [get_bd_pins $sink]
}
create_bd_cell -type module -reference qr_frame_pingpong frame_queue
create_bd_cell -type module -reference qr_binary_pingpong_address binary_pingpong
set_property CONFIG.Write_Depth_A {19200} [get_bd_cells blk_mem_gen_0]
# BRAM_Controller derives depth from its master's interface MEM_SIZE. The new
# bank adapter is that master and declares 76800 bytes, with one-cycle latency.
foreach pin {clkb rstb enb web addrb dinb doutb} {detach blk_mem_gen_0/$pin}
connect_bd_intf_net [get_bd_intf_pins binary_pingpong/bram_read] [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTB]
foreach pair {
 {vision_frontend_ip_0/wr_addr binary_pingpong/write_word}
 {vision_frontend_ip_0/wr_en binary_pingpong/write_enable}
 {qr_vcc_frontend_ip_t_0/bram_addr binary_pingpong/read_word}
 {qr_vcc_frontend_ip_t_0/bram_we binary_pingpong/read_write_enable}
 {frame_queue/write_bank binary_pingpong/write_bank}
 {frame_queue/read_bank binary_pingpong/read_bank}
 {binary_pingpong/write_byte blk_mem_gen_0/addra}
 {binary_pingpong/write_lanes blk_mem_gen_0/wea}
 {qr_vcc_frontend_ip_t_0/bram_clk binary_pingpong/reader_clk}
 {qr_vcc_frontend_ip_t_0/bram_rst binary_pingpong/reader_reset}
 {qr_vcc_frontend_ip_t_0/bram_en binary_pingpong/reader_enable}
 {qr_vcc_frontend_ip_t_0/bram_din binary_pingpong/reader_din}
 {binary_pingpong/reader_dout qr_vcc_frontend_ip_t_0/bram_dout}
 {processing_system7_0/FCLK_CLK0 frame_queue/aclk}
 {proc_sys_reset_0/peripheral_aresetn frame_queue/aresetn}
 {qr_rgb565_gray8_axis_0/frame_sof_accept frame_queue/capture_sof}
 {qr_rgb565_gray8_axis_0/image_tx_done frame_queue/capture_image_done}
 {qr_rgb565_gray8_axis_0/image_frame_id frame_queue/capture_image_id}
 {vision_frontend_ip_0/frame_ready frame_queue/frontend_ready}
 {vision_frontend_ip_0/valid_margin frame_queue/frontend_margin}
 {vision_frontend_ip_0/fe_mode_applied frame_queue/frontend_mode}
 {qr_runtime_exact_0/frontend_frame_release frame_queue/consumer_release}
 {qr_runtime_exact_0/image_capture_enable frame_queue/capture_enable}
 {frame_queue/capture_allowed qr_rgb565_gray8_axis_0/capture_enable}
 {frame_queue/capture_release qr_rgb565_gray8_axis_0/frame_release}
 {frame_queue/capture_release vision_frontend_ip_0/pl_frame_release}
 {frame_queue/capture_next_id qr_rgb565_gray8_axis_0/next_frame_id}
 {frame_queue/consumer_sof qr_runtime_exact_0/frame_sof_accept}
 {frame_queue/consumer_image_done qr_runtime_exact_0/image_tx_done}
 {frame_queue/consumer_image_id qr_runtime_exact_0/image_frame_id}
 {frame_queue/consumer_ready qr_runtime_exact_0/frontend_frame_ready}
 {frame_queue/consumer_margin qr_runtime_exact_0/frontend_valid_margin}
 {frame_queue/consumer_mode qr_runtime_exact_0/fe_mode_applied}
} {wire_to [lindex $pair 0] [lindex $pair 1]}
# Keep tap frontend_ready connected to the physical writer, not the consumer.
set interconnect [get_bd_cells axi_smc]
if {[llength $interconnect] != 1} {error "Ambiguous AXI control interconnect"}
set ic [get_property NAME $interconnect]
if {[get_property CONFIG.NUM_MI $interconnect] != 9} {error "Unexpected control ports"}
set_property CONFIG.NUM_MI 10 $interconnect
connect_bd_intf_net [get_bd_intf_pins $ic/M09_AXI] [get_bd_intf_pins frame_queue/s_axi]
assign_bd_address -offset 0x43C40000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs frame_queue/s_axi/reg0] -force
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {3} CONFIG.TDATA_REMAP {tdata[15:11],tdata[15:13],tdata[10:5],tdata[10:9],tdata[4:0],tdata[4:2]} CONFIG.TSTRB_REMAP {1'b1,tstrb[1:0]}] [get_bd_cells axis_subset_converter_rgb565]
if {[info exists hdmi_frame_tags] && $hdmi_frame_tags} {
    source [file join $root tools add_hdmi_frame_tags.tcl]
}
validate_bd_design
if {[get_property CONFIG.Write_Depth_A [get_bd_cells blk_mem_gen_0]] != 19200} {error "BMG depth propagation changed"}
save_bd_design
write_bd_tcl -force [file join $out design.tcl]
generate_target all $bd
puts [exec pwsh.exe -NoProfile -File [file join $root tools verify_frame_pingpong.ps1] -BuildName $name]
add_files -norecurse [make_wrapper -files $bd -top]
set_property top qr_ip1_bd_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $root hardware constraints zybo_z7_20_ov7670_stage4.xdc]
set_property PROCESSING_ORDER LATE [get_files *zybo_z7_20_ov7670_stage4.xdc]
update_compile_order -fileset sources_1
source [file join $root tools finish_frame_pingpong_build.tcl]
