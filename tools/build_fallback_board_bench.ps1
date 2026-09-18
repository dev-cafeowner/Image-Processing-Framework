param([switch]$FastFallback)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$src=Join-Path $root 'software/vitis/Qr_barcode_working_ver0_app/src'
$bsp=Join-Path $root 'Vitis_run/qr_verified_platform/export/qr_verified_platform/sw/standalone_ps7_cortexa9_0'
$profile=if($FastFallback){'fallback_bench_fast'}else{'fallback_bench_control'}
$out=Join-Path $root "Vitis_video30_stage4/$profile"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$gcc='C:/Xilinx/Vitis/2024.2/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe'
$units=@('qr_candidate_geometry.c','quirc.c','identify.c','decode.c','version_db.c','qr_decode.c','platform.c') | ForEach-Object {Join-Path $src $_}
& $gcc -O2 -g3 -DSDT -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -std=c99 -Wall -Wextra -Wno-unused-parameter `
    "-specs=$bsp/Xilinx.spec" "-I$bsp/include" "-I$src" `
    -DQR_PL_GUIDED=1 -DQR_GUIDED_EARLY_DECODE=1 -DQR_GUIDED_SEED_RADIUS_MIN=8 `
    "-DQR_FALLBACK_EARLY_DECODE=$([int]$FastFallback.IsPresent)" -DQR_PER_FRAME_LOGS=0 -DQR_ROUTE_AUDIT=0 `
    "$root/software/tests/qr_fallback_board_bench.c" @units `
    "-Wl,-T,$src/lscript.ld" "-L$bsp/lib" `
    '-Wl,--start-group,-lxilstandalone,-lxiltimer,-lxil,-lgcc,-lc,-lm,--end-group' `
    -o "$out/qr_fallback_bench.elf"
if($LASTEXITCODE){throw 'Board benchmark build failed'}
Get-FileHash -LiteralPath "$out/qr_fallback_bench.elf" -Algorithm SHA256
