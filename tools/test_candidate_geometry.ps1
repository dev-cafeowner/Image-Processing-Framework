param([switch]$EarlyDecode,[switch]$FastFallback,[ValidateSet('4','8','12')][string]$SeedRadius='4')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$src=Join-Path $root 'software/vitis/Qr_barcode_working_ver0_app/src'
$out=Join-Path $root 'Vitis_video30_stage4/candidate_host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:/Xilinx/Vivado/2024.2/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe' -std=c99 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare -Wno-type-limits -static `
    -DQR_PL_GUIDED=1 "-DQR_FALLBACK_EARLY_DECODE=$([int]$FastFallback.IsPresent)" "-DQR_GUIDED_EARLY_DECODE=$([int]$EarlyDecode.IsPresent)" "-DQR_GUIDED_SEED_RADIUS_MIN=$SeedRadius" "-I$src" "-I$root/software/tests/qr_guided_mock" "-I$root/software/tests/video_overlay_mock" `
    "$root/software/tests/qr_candidate_geometry_test.c" "$src/qr_candidate_geometry.c" "$src/quirc.c" "$src/identify.c" "$src/decode.c" "$src/version_db.c" "$src/qr_decode.c" `
    -lm -o "$out/qr_candidate_geometry_test.exe"
if($LASTEXITCODE){throw 'Candidate geometry host build failed'}
& "$out/qr_candidate_geometry_test.exe"
if($LASTEXITCODE){throw 'Candidate geometry regression failed'}
