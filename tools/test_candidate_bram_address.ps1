param([switch]$PingPong)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/candidate_bram_address_sim'
if($PingPong){$out=Join-Path $root 'Vivado/pingpong_candidate_bram_sim'}
New-Item -ItemType Directory -Force -Path $out | Out-Null
$files=@(
 'hardware/rtl/bridge/qr_binary_bram_address_adapter.v',
 'hardware/rtl/bridge/qr_binary_pingpong_address.v',
 $(if($PingPong){'Vivado/qr_frame_pingpong/qr_frame_pingpong.gen/sources_1/bd/vivado/ip/qr_ip1_bd_blk_mem_gen_0_0/sim/qr_ip1_bd_blk_mem_gen_0_0.v'}else{'Vivado/qr_video30_stage4/qr_video30_stage4.gen/sources_1/bd/vivado/ip/qr_ip1_bd_blk_mem_gen_0_0/sim/qr_ip1_bd_blk_mem_gen_0_0.v'}),
 'hardware/rtl/qr_feature/qr_runlength_vcc_core_rv56_fix.v',
 'hardware/rtl/qr_feature/qr_vcc_event_axis_packer.v',
 'hardware/rtl/qr_feature/qr_vcc_frontend_ip_top.v',
 'hardware/rtl/runtime/qr_event_fifo.v','hardware/rtl/runtime/qr_sparse_ccl.v',
 'hardware/rtl/runtime/qr_object_properties.v','hardware/rtl/runtime/qr_result_packet_builder_qrp1.v',
 'hardware/rtl/runtime/qr_postprocess_axis_qrp1_core.v','hardware/rtl/runtime/qr_error_flag_mapper.v',
 'hardware/tb/qr_candidate_bram_address_tb.sv') | ForEach-Object {Join-Path $root $_}
Push-Location $out
try {
 $defines=@(); if($PingPong){$defines=@('--define','QR_TEST_PINGPONG')}
 & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv @defines @files
 if($LASTEXITCODE){throw 'Compile failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' -L blk_mem_gen_v8_4_9 qr_candidate_bram_address_tb -s candidate_address
 if($LASTEXITCODE){throw 'Elaboration failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' candidate_address -runall -log candidate_address.log
 if($LASTEXITCODE -or !(Select-String -LiteralPath candidate_address.log -Pattern '^PASS:') -or (Select-String -LiteralPath candidate_address.log -Pattern 'Fatal:|Error:')){throw 'Candidate address regression failed'}
} finally {Pop-Location}
