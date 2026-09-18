param(
    [ValidateSet('O0','O2')][string]$Optimization = 'O2',
    [string]$Source = 'software/vitis/Qr_barcode_working_ver0_app/src',
    [string]$Build = 'Vitis_video30_stage1/build',
    [switch]$BlankTest,
    [ValidateSet('0','1','128','129')][string]$CameraClock = '1',
    [switch]$LegacyPreview,
    [switch]$PerFrameLogs,
    [switch]$ScalarPixels,
    [switch]$PlPreview,
    [switch]$SourceSyncCamera,
    [ValidateSet('0','1','2','3')][string]$CameraDrive = '1',
    [switch]$Colorbars,
    [switch]$CleanPclk,
    [switch]$CandidateAudit,
    [switch]$PlGuided,
    [switch]$GuidedEarlyDecode,
    [switch]$FastFallback,
    [switch]$RouteAudit,
    [switch]$FallbackTest,
    [ValidateSet('4','8','12')][string]$GuidedSeedRadius = '4',
    [switch]$PipelineTrace,
    [switch]$PingPong,
    [switch]$PingPongStallTest,
    [ValidateSet('100','1000')][string]$WaitPollUs = '1000',
    [ValidateSet('4','12','13','61')][string]$FrontendMode = '61'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($PlPreview -and $Build -eq 'Vitis_video30_stage1/build') {
    throw 'Use -Build Vitis_video30_stage2/build to preserve the stage1 ELF'
}
if (($CameraClock -in @('128','129') -or $Colorbars) -and !$SourceSyncCamera) {throw 'Fast/pattern camera requires CAM3 source-synchronous hardware'}
if ($SourceSyncCamera -and (!$PlPreview -or ($Build -notlike 'Vitis_video30_stage3/*' -and $Build -notlike 'Vitis_video30_stage4/*'))) {throw 'Source-sync requires -PlPreview and a separate stage3/stage4 build directory'}
if ($CleanPclk -and (!$SourceSyncCamera -or $CameraClock -ne '128' -or $Build -notlike 'Vitis_video30_stage4/*')) {throw 'CleanPclk requires stage4, source-sync and CLKRC=128 (24MHz PCLK)'}
if (!$CleanPclk -and $Build -like 'Vitis_video30_stage4/*') {throw 'Stage4 requires -CleanPclk'}
Set-Location $root
$bsp = "$root/Vitis_run/qr_verified_platform/export/qr_verified_platform/sw/standalone_ps7_cortexa9_0".Replace('\','/')
$cmake = 'C:/Xilinx/Vitis/2024.2/tps/win64/cmake-3.24.2/bin/cmake.exe'
$env:PATH = 'C:/Xilinx/Vitis/2024.2/gnu/aarch32/nt/gcc-arm-none-eabi/bin;' + $env:PATH
& $cmake -S $Source -B $Build -G Ninja `
    '-DCMAKE_MAKE_PROGRAM=C:/Xilinx/Vitis/2024.2/tps/win64/lopper-1.1.0-packages/min_sdk/usr/bin/ninja.exe' `
    "-DCMAKE_TOOLCHAIN_FILE=$bsp/cortexa9_toolchain.cmake" `
    "-DCMAKE_SPECS_FILE=$bsp/Xilinx.spec" `
    "-DCMAKE_INCLUDE_PATH=$bsp/include" "-DCMAKE_LIBRARY_PATH=$bsp/lib" `
    "-DCMAKE_MODULE_PATH=$bsp" "-DQR_OPTIMIZATION=-$Optimization" `
    "-DQR_PERF_BLANK_TEST=$($BlankTest.IsPresent.ToString().ToUpper())" `
    "-DQR_CAMERA_CLKRC=$CameraClock" `
    "-DQR_PREVIEW_FUSED=$((!$LegacyPreview.IsPresent).ToString().ToUpper())" `
    "-DQR_PER_FRAME_LOGS=$($PerFrameLogs.IsPresent.ToString().ToUpper())" `
    "-DQR_CANDIDATE_AUDIT=$($CandidateAudit.IsPresent.ToString().ToUpper())" `
    "-DQR_PL_GUIDED=$($PlGuided.IsPresent.ToString().ToUpper())" `
    "-DQR_GUIDED_EARLY_DECODE=$($GuidedEarlyDecode.IsPresent.ToString().ToUpper())" `
    "-DQR_FALLBACK_EARLY_DECODE=$($FastFallback.IsPresent.ToString().ToUpper())" `
    "-DQR_ROUTE_AUDIT=$($RouteAudit.IsPresent.ToString().ToUpper())" `
    "-DQR_FALLBACK_TEST=$($FallbackTest.IsPresent.ToString().ToUpper())" `
    "-DQR_GUIDED_SEED_RADIUS_MIN=$GuidedSeedRadius" `
    "-DQR_PIPELINE_TRACE=$($PipelineTrace.IsPresent.ToString().ToUpper())" `
    "-DQR_PINGPONG=$($PingPong.IsPresent.ToString().ToUpper())" `
    "-DQR_PINGPONG_STALL_TEST=$($PingPongStallTest.IsPresent.ToString().ToUpper())" `
    "-DQR_WAIT_POLL_US=$WaitPollUs" `
    "-DQR_FRONTEND_MODE=$FrontendMode" `
    "-DQR_PREVIEW_NEON=$((!$ScalarPixels.IsPresent).ToString().ToUpper())" `
    "-DQR_PL_PREVIEW=$($PlPreview.IsPresent.ToString().ToUpper())" `
    "-DQR_CAMERA_SOURCE_SYNC=$($SourceSyncCamera.IsPresent.ToString().ToUpper())" `
    "-DQR_CAMERA_DRIVE=$CameraDrive" `
    "-DQR_CAMERA_CLEAN_PCLK=$($CleanPclk.IsPresent.ToString().ToUpper())" `
    "-DQR_CAMERA_COLORBARS=$($Colorbars.IsPresent.ToString().ToUpper())"
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed' }
& $cmake --build $Build --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Application build failed' }
$commands = Get-Content "$Build/compile_commands.json" -Raw | ConvertFrom-Json
foreach ($entry in $commands) {
    $flags = [regex]::Matches($entry.command, '(?<!\S)-O[0-3sg](?!\S)')
    $expected = "-$Optimization"
    if ($flags.Count -eq 0 -or $flags[$flags.Count-1].Value -ne $expected) {
        throw "Unexpected optimization flags: $($entry.file)"
    }
}
Write-Output "Verified effective -$Optimization for all $($commands.Count) compilation units. Existing bitstream and Vitis_run ELF were not changed."
