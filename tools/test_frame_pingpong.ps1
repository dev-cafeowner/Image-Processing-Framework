$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/frame_pingpong_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$files=@('hardware/rtl/bridge/qr_frame_pingpong.v','hardware/rtl/bridge/qr_binary_pingpong_address.v',
 'hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v','hardware/rtl/frontend/binary_frame_writer.v',
 'hardware/rtl/runtime/qr_frame_id_control.v','hardware/rtl/runtime/qr_frame_completion_ctrl.v',
 'hardware/tb/qr_frame_pingpong_tb.sv') | ForEach-Object {Join-Path $root $_}
Push-Location $out
try {
 & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv @files
 if($LASTEXITCODE){throw 'Compile failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' qr_frame_pingpong_tb -s frame_pingpong
 if($LASTEXITCODE){throw 'Elaboration failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' frame_pingpong -runall -log frame_pingpong.log
 if($LASTEXITCODE -or !(Select-String -LiteralPath frame_pingpong.log -Pattern '^PASS:') -or (Select-String -LiteralPath frame_pingpong.log -Pattern 'Fatal:|Error:')){throw 'Pingpong regression failed'}
} finally {Pop-Location}
