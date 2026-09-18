$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vitis_video30_stage4/candidate_host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -static `
    "-I$root/software/vitis/Qr_barcode_working_ver0_app/src" `
    "$root/software/tests/qr_candidate_packet_test.c" -o "$out/qr_candidate_packet_test.exe"
if($LASTEXITCODE){throw 'Candidate packet host build failed'}
& "$out/qr_candidate_packet_test.exe"
if($LASTEXITCODE){throw 'Candidate packet regression failed'}
