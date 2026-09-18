$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$src=Join-Path $root 'software/vitis/Qr_barcode_working_ver0_app/src'
$out=Join-Path $root 'Vitis_video30_stage4/pipeline_host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -static `
    "-I$src" "-I$root/software/tests/video_overlay_mock" `
    "$root/software/tests/qr_pipeline_trace_test.c" "$src/qr_pipeline_trace.c" -o "$out/qr_pipeline_trace_test.exe"
if($LASTEXITCODE){throw 'Pipeline trace host build failed'}
& "$out/qr_pipeline_trace_test.exe"
if($LASTEXITCODE){throw 'Pipeline trace regression failed'}
