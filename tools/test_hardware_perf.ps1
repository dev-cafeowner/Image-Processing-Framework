$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Vivado/qr_perf_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & 'C:/Xilinx/Vivado/2024.2/bin/xvlog.bat' --sv "$root/hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v" "$root/hardware/tb/qr_rgb565_gray8_axis_tap_tb.sv" "$root/hardware/rtl/camera/ov7670_capture.v" "$root/hardware/tb/ov7670_fast_capture_tb.sv"
    if ($LASTEXITCODE) { throw 'Compile failed' }
    & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' qr_rgb565_gray8_axis_tap_tb -s tap_test
    if ($LASTEXITCODE) { throw 'Elaboration failed' }
    & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' tap_test -runall
    if ($LASTEXITCODE -or !(Select-String -Path xsim.log -Pattern '^PASS:')) { throw 'Simulation failed' }
    Copy-Item -LiteralPath xsim.log -Destination tap_test.log -Force
    & 'C:/Xilinx/Vivado/2024.2/bin/xelab.bat' ov7670_fast_capture_tb -s camera_test
    if ($LASTEXITCODE) { throw 'Camera elaboration failed' }
    & 'C:/Xilinx/Vivado/2024.2/bin/xsim.bat' camera_test -runall
    if ($LASTEXITCODE -or !(Select-String -Path xsim.log -Pattern '^PASS:')) { throw 'Camera simulation failed' }
    Copy-Item -LiteralPath xsim.log -Destination camera_test.log -Force
} finally { Pop-Location }
