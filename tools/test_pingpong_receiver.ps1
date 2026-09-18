$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/frame_pingpong_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -DQR_PINGPONG_HOST_TEST=1 `
 "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" "-I$root/software/tests/pingpong_mock" "-I$root/software/tests/video_overlay_mock" `
 "$root/software/tests/qr_pingpong_test.c" "$root/software/vitis/Qr_barcode_working_ver0_app/src/qr_pingpong.c" -o "$out/test_pingpong_receiver.exe"
if($LASTEXITCODE){throw 'Receiver test compile failed'}
& "$out/test_pingpong_receiver.exe"
if($LASTEXITCODE){throw 'Receiver regression failed'}
