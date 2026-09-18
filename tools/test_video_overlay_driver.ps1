$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vitis_video30_stage2/host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -static `
    "-I$root/software/tests/video_overlay_mock" "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" `
    "$root/software/tests/video_overlay_test.c" "$root/software/vitis/Qr_barcode_working_ver0_app/src/video_overlay.c" -o "$out/video_overlay_test.exe"
if($LASTEXITCODE) {throw 'HUD driver regression build failed'}
& "$out/video_overlay_test.exe"
if($LASTEXITCODE) {throw 'HUD driver regression failed'}
