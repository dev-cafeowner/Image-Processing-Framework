# Called within the isolated cadence build, after normal QPP1 wiring.
add_files [file join $root hardware rtl video video_frame_tag.v]
update_compile_order -fileset sources_1
foreach cell {camera_tag scan_tag} {
    create_bd_cell -type module -reference video_frame_tag $cell
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins $cell/aclk]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins $cell/aresetn]
}
set_property CONFIG.SCAN_TAG 1 [get_bd_cells scan_tag]
# Disconnect interface plus monitor scalar taps to avoid bypassing the marker's
# elastic ready/valid stage via the original merged BD scalar net.
foreach pin {camera_ready camera_sof camera_valid} {detach video_preview_overlay_0/$pin}
foreach pair {
    {axis_subset_converter_rgb565/M_AXIS axi_vdma_0/S_AXIS_S2MM camera_tag}
    {video_preview_overlay_0/m_axis v_axi4s_vid_out_0/video_in scan_tag}
} {
    lassign $pair source sink tag
    set net [get_bd_intf_nets -of_objects [get_bd_intf_pins $sink]]
    disconnect_bd_intf_net $net [get_bd_intf_pins $sink]
    connect_bd_intf_net [get_bd_intf_pins $source] [get_bd_intf_pins $tag/s_axis]
    connect_bd_intf_net [get_bd_intf_pins $tag/m_axis] [get_bd_intf_pins $sink]
}
foreach pair {{m_axis_tready camera_ready} {m_axis_tuser camera_sof} {m_axis_tvalid camera_valid}} {
    # Explicitly rewire all formerly overridden scalar pins as well as the
    # interface. BD remembers scalar overrides after an interface disconnect.
    detach camera_tag/[lindex $pair 0]
}
foreach pair {
 {axis_subset_converter_rgb565/m_axis_tdata camera_tag/s_axis_tdata}
 {axis_subset_converter_rgb565/m_axis_tvalid camera_tag/s_axis_tvalid}
 {camera_tag/s_axis_tready axis_subset_converter_rgb565/m_axis_tready}
 {axis_subset_converter_rgb565/m_axis_tuser camera_tag/s_axis_tuser}
 {axis_subset_converter_rgb565/m_axis_tlast camera_tag/s_axis_tlast}
 {camera_tag/m_axis_tdata axi_vdma_0/s_axis_s2mm_tdata}
 {camera_tag/m_axis_tvalid axi_vdma_0/s_axis_s2mm_tvalid}
 {axi_vdma_0/s_axis_s2mm_tready camera_tag/m_axis_tready}
 {camera_tag/m_axis_tuser axi_vdma_0/s_axis_s2mm_tuser}
 {camera_tag/m_axis_tlast axi_vdma_0/s_axis_s2mm_tlast}
 {camera_tag/m_axis_tready video_preview_overlay_0/camera_ready}
 {camera_tag/m_axis_tuser video_preview_overlay_0/camera_sof}
 {camera_tag/m_axis_tvalid video_preview_overlay_0/camera_valid}
} {wire_to [lindex $pair 0] [lindex $pair 1]}
