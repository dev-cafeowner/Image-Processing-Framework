$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Vitis_video30_stage1/host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$compiler = 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe'
& $compiler -std=c99 -O2 -Wall -Wextra -Werror -static `
    "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" `
    "$root/software/tests/video_pixel_ops_test.c" `
    "$root/software/vitis/Qr_barcode_working_ver0_app/src/video_pixel_ops.c" -o "$out/video_pixel_ops_test.exe"
if ($LASTEXITCODE) { throw 'Pixel regression build failed' }
& "$out/video_pixel_ops_test.exe"
if ($LASTEXITCODE) { throw 'Pixel regression failed' }
& $compiler -std=c99 -O2 -Wall -Wextra -Werror -static -DRUNTIME_LOG_HOST_TEST `
    "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" `
    "$root/software/tests/runtime_log_test.c" `
    "$root/software/vitis/Qr_barcode_working_ver0_app/src/runtime_log.c" `
    -o "$out/runtime_log_test.exe"
if ($LASTEXITCODE) { throw 'Logger regression build failed' }
& "$out/runtime_log_test.exe"
if ($LASTEXITCODE) { throw 'Logger regression failed' }
