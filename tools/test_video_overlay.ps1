$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Vivado/video_overlay_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv "$root/hardware/rtl/video/video_preview_overlay.v" "$root/hardware/tb/video_preview_overlay_tb.sv"
    if ($LASTEXITCODE) { throw 'Compile failed' }
    foreach ($case in @('small','vga')) {
        $top = 'video_preview_overlay_tb'
        if ($case -eq 'vga') { $top = 'video_preview_overlay_vga_tb' }
        & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' $top -s "overlay_$case"
        if ($LASTEXITCODE) { throw 'Elaboration failed' }
        & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' "overlay_$case" -runall
        if ($LASTEXITCODE -or !(Select-String -Path xsim.log -Pattern '^PASS:')) { throw 'Simulation failed' }
        Copy-Item -LiteralPath xsim.log -Destination "overlay_$case.log" -Force
    }
} finally { Pop-Location }
