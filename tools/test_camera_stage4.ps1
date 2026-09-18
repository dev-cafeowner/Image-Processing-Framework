$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/camera_stage4_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv "$root/hardware/rtl/camera/ov7670_pclk_rx.v" "$root/hardware/rtl/camera/ov7670_camera_clock.v" "$root/hardware/rtl/camera/ov7670_pclk_clean_clock.v" "$root/hardware/rtl/camera/ov7670_clean_sync_axis.v" "$root/hardware/tb/ov7670_clean_pclk_rx_tb.sv" "$root/hardware/tb/ov7670_clean_sync_axis_tb.sv" 'C:/Xilinx/Vivado/2024.2/data/verilog/src/glbl.v'
    if($LASTEXITCODE) {throw 'Camera stage4 compile failed'}
    foreach($mode in @('small','vga','control')) {
        $top=switch($mode) {'small' {'ov7670_clean_pclk_rx_tb'} 'vga' {'ov7670_clean_pclk_rx_vga_tb'} 'control' {'ov7670_clean_sync_axis_tb'}}
        & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' -L xpm -L unisims_ver $top glbl -s "camera_$mode"
        if($LASTEXITCODE) {throw "Camera $mode elaboration failed"}
        & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' "camera_$mode" -runall -log "camera_$mode.log"
        if($LASTEXITCODE -or !(Select-String -LiteralPath "camera_$mode.log" -Pattern '^PASS:') -or (Select-String -LiteralPath "camera_$mode.log" -Pattern 'Error:|Fatal:|\$error')) {throw "Camera $mode simulation failed"}
    }
} finally {Pop-Location}
