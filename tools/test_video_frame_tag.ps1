$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/frame_tag_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
 & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv "$root/hardware/rtl/video/video_frame_tag.v" "$root/hardware/tb/video_frame_tag_tb.sv"
 if($LASTEXITCODE){throw 'Compile failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' video_frame_tag_tb -s frame_tag
 if($LASTEXITCODE){throw 'Elaboration failed'}
 & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' frame_tag -runall -log frame_tag.log
 if($LASTEXITCODE -or !(Select-String frame_tag.log -Pattern '^PASS:') -or (Select-String frame_tag.log -Pattern 'Fatal:|Error:')){throw 'Tag simulation failed'}
} finally {Pop-Location}
