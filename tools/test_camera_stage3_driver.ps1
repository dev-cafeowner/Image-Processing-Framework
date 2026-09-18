$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vitis_video30_stage3/host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
foreach($clean in 0..1) {
 foreach($drive in 0..3) {
  foreach($pattern in 0..1) {
    & 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -static `
        "-DQR_CAMERA_DRIVE=$drive" "-DQR_CAMERA_COLORBARS=$pattern" "-DQR_CAMERA_CLEAN_PCLK=$clean" `
        "-I$root/software/tests/camera_stage3_mock" "-I$root/software/tests/video_overlay_mock" `
        "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" `
        "$root/software/tests/camera_stage3_test.c" "$root/software/vitis/Qr_barcode_working_ver0_app/src/camera_stage3.c" `
        -o "$out/camera_stage3_test.exe"
    if($LASTEXITCODE) {throw 'Camera driver host build failed'}
    & "$out/camera_stage3_test.exe"
    if($LASTEXITCODE) {throw 'Camera driver regression failed'}
  }
}
}
