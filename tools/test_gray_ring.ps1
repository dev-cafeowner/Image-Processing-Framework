$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/frame_pingpong_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" "$root/tools/tests/test_gray_ring.c" -o "$out/test_gray_ring.exe"
if($LASTEXITCODE){throw 'Host compile failed'}
& "$out/test_gray_ring.exe"
if($LASTEXITCODE){throw 'Gray ring test failed'}
