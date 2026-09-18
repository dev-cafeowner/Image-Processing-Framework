# New project only. Never overwrite the qualified Stage4 project/artifacts.
set root [file dirname [file dirname [file normalize [info script]]]]
set name qr_candidate_address_fix
set out [file join $root Vivado $name]
if {[file exists [file join $out ${name}.bit]]} {error "Qualified output exists; do not overwrite"}
if {[file exists [file join $out ${name}.xpr]]} {
open_project [file join $out ${name}.xpr]
} else {
create_project $name $out -part xc7z020clg400-1
set_property ip_repo_paths [list [file join $root hardware ip_repo custom] [file join $root hardware ip_repo runtime] [file join $root Vivado deps digilent-vivado-library ip] [file join $root Vivado deps digilent-vivado-library if]] [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
update_ip_catalog
foreach path {hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v hardware/rtl/bridge/qr_binary_bram_address_adapter.v hardware/rtl/video/video_preview_overlay.v hardware/rtl/camera/ov7670_camera_clock.v hardware/rtl/camera/ov7670_pclk_rx.v hardware/rtl/camera/ov7670_clean_sync_axis.v hardware/rtl/camera/ov7670_pclk_clean_clock.v} {
    add_files [file join $root $path]
}
set seed [file join $root Vivado candidate_address_seed vivado]
file mkdir $seed
file copy [file join $root Vivado qr_video30_stage4 qr_video30_stage4.srcs sources_1 bd vivado qr_ip1_bd.bd] [file join $seed qr_ip1_bd.bd]
import_files [file join $seed qr_ip1_bd.bd]
}
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
validate_bd_design
if {[llength [get_bd_cells -quiet binary_address_adapter]] == 0} {
set mem [get_bd_cells blk_mem_gen_0]
# Freeze the existing memory geometry/latency before removing interface inference.
set_property -dict [list CONFIG.use_bram_block {BRAM_Controller} CONFIG.Enable_32bit_Address {true} CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.Write_Width_A {32} CONFIG.Read_Width_A {32} CONFIG.Write_Width_B {32} CONFIG.Read_Width_B {32} CONFIG.Write_Depth_A {9600} CONFIG.Use_Byte_Write_Enable {true} CONFIG.Byte_Size {8} CONFIG.Register_PortA_Output_of_Memory_Primitives {false} CONFIG.Register_PortA_Output_of_Memory_Core {false} CONFIG.Register_PortB_Output_of_Memory_Primitives {false} CONFIG.Register_PortB_Output_of_Memory_Core {false} CONFIG.Use_RSTA_Pin {true} CONFIG.Use_RSTB_Pin {true}] $mem
set reader [get_bd_cells -filter {VLNV =~ *:qr_vcc_frontend_ip_top:*}]
if {[llength $reader] != 1} {error "Expected one feature reader: $reader"}
set reader_name [get_property NAME $reader]
set intf [get_bd_intf_nets -of_objects [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTB]]
if {[llength $intf] != 1} {error "Expected old BRAM port B interface"}
delete_bd_objs $intf
proc disconnect_pin {path} {
    set pin [get_bd_pins $path]
    foreach net [get_bd_nets -quiet -of_objects $pin] {disconnect_bd_net $net $pin}
}
disconnect_pin blk_mem_gen_0/addra
disconnect_pin blk_mem_gen_0/wea
create_bd_cell -type module -reference qr_binary_bram_address_adapter binary_address_adapter
foreach pair {{vision_frontend_ip_0/wr_addr binary_address_adapter/write_word} {vision_frontend_ip_0/wr_en binary_address_adapter/write_enable} {binary_address_adapter/write_byte blk_mem_gen_0/addra} {binary_address_adapter/read_byte blk_mem_gen_0/addrb} {binary_address_adapter/write_lanes blk_mem_gen_0/wea} {binary_address_adapter/read_write_lanes blk_mem_gen_0/web}} {
    connect_bd_net [get_bd_pins [lindex $pair 0]] [get_bd_pins [lindex $pair 1]]
}
connect_bd_net [get_bd_pins $reader_name/bram_addr] [get_bd_pins binary_address_adapter/read_word]
connect_bd_net [get_bd_pins $reader_name/bram_we] [get_bd_pins binary_address_adapter/read_write_enable]
foreach pair {{bram_clk clkb} {bram_rst rstb} {bram_en enb} {bram_din dinb} {bram_dout doutb}} {
    connect_bd_net [get_bd_pins $reader_name/[lindex $pair 0]] [get_bd_pins blk_mem_gen_0/[lindex $pair 1]]
}
}
# Importing a module-reference camera can reset the subset converter defaults.
# Preserve exactly the Stage4 RGB565 -> RGB888 expansion.
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {3} CONFIG.TDATA_REMAP {tdata[15:11],tdata[15:13],tdata[10:5],tdata[10:9],tdata[4:0],tdata[4:2]} CONFIG.TSTRB_REMAP {1'b1,tstrb[1:0]}] [get_bd_cells axis_subset_converter_rgb565]
validate_bd_design
save_bd_design
write_bd_tcl -force [file join $out design.tcl]
generate_target all $bd
puts [exec pwsh.exe -NoProfile -File [file join $root tools verify_candidate_address_fix.ps1]]
add_files -norecurse [make_wrapper -files $bd -top]
set_property top qr_ip1_bd_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $root hardware constraints zybo_z7_20_ov7670_stage4.xdc]
set_property PROCESSING_ORDER LATE [get_files *zybo_z7_20_ov7670_stage4.xdc]
update_compile_order -fileset sources_1
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
if {[string first "VIOLATED" $skew] >= 0} {error "CDC skew failed; do not deploy"}
set samples [get_cells -hier -filter {NAME =~ *ov7670_axis_0/inst/receiver/pin_sample_reg* && REF_NAME == FDRE}]
if {[llength $samples] != 10} {error "Expected ten camera input registers"}
foreach cell $samples {if {![string match "ILOGIC*" [get_property LOC $cell]]} {error "Camera input register not in IOB"}}
if {abs([get_property PERIOD [get_clocks clk_fpga_0]] - 16.0) > 0.01 || abs([get_property PERIOD [get_clocks cam_xclk_out]] - 41.6667) > 0.01} {error "Clocks changed"}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 || [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Timing failed; do not deploy"}
write_hw_platform -fixed -include_bit -file [file join $out ${name}.xsa]
file copy [file join $out ${name}.runs impl_1 qr_ip1_bd_wrapper.bit] [file join $out ${name}.bit]
puts "CANDIDATE_ADDRESS_FIX_HARDWARE_PASS"
close_project
exit
