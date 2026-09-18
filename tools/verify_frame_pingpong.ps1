param([ValidateSet('qr_frame_pingpong','qr_hdmi_cadence')][string]$BuildName='qr_frame_pingpong')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$base=Join-Path $root "Vivado/$BuildName/$BuildName"
$memory=Get-Content "$base.gen/sources_1/bd/vivado/ip/qr_ip1_bd_blk_mem_gen_0_0/sim/qr_ip1_bd_blk_mem_gen_0_0.v" -Raw
foreach($p in @(@('C_WRITE_DEPTH_A',19200),@('C_WRITE_DEPTH_B',19200),@('C_ADDRA_WIDTH',32),@('C_ADDRB_WIDTH',32),@('C_HAS_MEM_OUTPUT_REGS_A',0),@('C_HAS_MEM_OUTPUT_REGS_B',0),@('C_HAS_MUX_OUTPUT_REGS_A',0),@('C_HAS_MUX_OUTPUT_REGS_B',0))) {
 if($memory -notmatch "\.$($p[0])\($($p[1])\)"){throw "Generated memory contract: $($p[0])"}
}
$rtl=Get-Content "$base.gen/sources_1/bd/vivado/synth/qr_ip1_bd.v" -Raw
function Wire([string]$cell,[string]$pin) {
 $body=[regex]::Match($rtl,"(?s)\b$cell\s*\((.*?)\);").Groups[1].Value
 $net=[regex]::Match($body,"\.$pin\(([^()]+)\)").Groups[1].Value
 if(!$net -or $net -match "'"){throw "Missing/truncated $cell/$pin"}; $net
}
foreach($p in @(
 @('frame_queue','capture_sof','qr_rgb565_gray8_axis_0','frame_sof_accept'),
 @('frame_queue','capture_release','vision_frontend_ip_0','pl_frame_release'),
 @('frame_queue','capture_release','qr_rgb565_gray8_axis_0','frame_release'),
 @('frame_queue','consumer_release','qr_runtime_exact_0','frontend_frame_release'),
 @('frame_queue','consumer_ready','qr_runtime_exact_0','frontend_frame_ready'),
 @('frame_queue','consumer_sof','qr_runtime_exact_0','frame_sof_accept'),
 @('frame_queue','consumer_image_id','qr_runtime_exact_0','image_frame_id'),
 @('frame_queue','consumer_image_done','qr_runtime_exact_0','image_tx_done'),
 @('frame_queue','capture_allowed','qr_rgb565_gray8_axis_0','capture_enable'),
 @('frame_queue','capture_next_id','qr_rgb565_gray8_axis_0','next_frame_id'),
 @('frame_queue','frontend_ready','vision_frontend_ip_0','frame_ready'),
 @('frame_queue','write_bank','binary_pingpong','write_bank'),
 @('frame_queue','read_bank','binary_pingpong','read_bank'),
 @('binary_pingpong','write_byte','blk_mem_gen_0','addra'),
 @('binary_pingpong','read_byte','blk_mem_gen_0','addrb'),
 @('binary_pingpong','write_lanes','blk_mem_gen_0','wea'),
 @('binary_pingpong','read_write_lanes','blk_mem_gen_0','web')
 )) {if((Wire $p[0] $p[1]) -ne (Wire $p[2] $p[3])){throw "Disconnected $p"}}
$old=Get-Content (Join-Path $root 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.srcs/sources_1/bd/vivado/qr_ip1_bd.bd') -Raw | ConvertFrom-Json
$new=Get-Content "$base.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
foreach($name in @('processing_system7_0','ov7670_axis_0','vision_frontend_ip_0','qr_vcc_frontend_ip_t_0','qr_runtime_exact_0','axi_dma_image','axi_dma_0','axi_vdma_0','axis_subset_converter_rgb565','video_preview_overlay_0')) {
 $a=$old.design.components.$name.parameters | ConvertTo-Json -Depth 50 -Compress
 $b=$new.design.components.$name.parameters | ConvertTo-Json -Depth 50 -Compress
 if($a -cne $b){throw "Unexpected IP parameter change: $name"}
}
'PASS: QPP1 generated bank/ownership wiring, 19200-word byte-address BMG, unchanged camera/feature/runtime/video/DMA parameters'
if($BuildName -eq 'qr_hdmi_cadence') {
 foreach($p in @(
 @('axis_subset_converter_rgb565','m_axis_tdata','camera_tag','s_axis_tdata'),
 @('axis_subset_converter_rgb565','m_axis_tvalid','camera_tag','s_axis_tvalid'),
 @('axis_subset_converter_rgb565','m_axis_tready','camera_tag','s_axis_tready'),
 @('axis_subset_converter_rgb565','m_axis_tuser','camera_tag','s_axis_tuser'),
 @('axis_subset_converter_rgb565','m_axis_tlast','camera_tag','s_axis_tlast'),
 @('camera_tag','m_axis_tdata','axi_vdma_0','s_axis_s2mm_tdata'),
 @('camera_tag','m_axis_tvalid','axi_vdma_0','s_axis_s2mm_tvalid'),
 @('camera_tag','m_axis_tready','axi_vdma_0','s_axis_s2mm_tready'),
 @('camera_tag','m_axis_tuser','axi_vdma_0','s_axis_s2mm_tuser'),
 @('camera_tag','m_axis_tlast','axi_vdma_0','s_axis_s2mm_tlast'),
 @('camera_tag','m_axis_tready','video_preview_overlay_0','camera_ready'),
 @('camera_tag','m_axis_tuser','video_preview_overlay_0','camera_sof'),
 @('camera_tag','m_axis_tvalid','video_preview_overlay_0','camera_valid'),
 @('video_preview_overlay_0','m_axis_tdata','scan_tag','s_axis_tdata'),
 @('video_preview_overlay_0','m_axis_tvalid','scan_tag','s_axis_tvalid'),
 @('video_preview_overlay_0','m_axis_tready','scan_tag','s_axis_tready'),
 @('scan_tag','m_axis_tdata','v_axi4s_vid_out_0','s_axis_video_tdata'),
 @('scan_tag','m_axis_tvalid','v_axi4s_vid_out_0','s_axis_video_tvalid'),
 @('scan_tag','m_axis_tready','v_axi4s_vid_out_0','s_axis_video_tready')
 )) {if((Wire $p[0] $p[1]) -ne (Wire $p[2] $p[3])){throw "Disconnected diagnostic tag $p"}}
 'PASS: generated diagnostic tag data/ready/valid/monitor paths'
}
