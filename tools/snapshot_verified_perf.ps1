param([ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name = 'qr_perf_stable_20260917')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $root "Vivado/releases/$Name"
$archive = "$destination.zip"
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $archive)) {
    throw 'Snapshot already exists; use a new name. Existing snapshots are never overwritten.'
}
$expected = @{
    'Vivado/qr_perf/qr_perf.bit' = 'CED9DF2757264BF9FFBD83018EBD65AA21D51FFC2C871D7048602DFBFEEF99B2'
    'Vivado/qr_perf/qr_perf.xsa' = '51884AD9A7FBD8AB15F2A2DC9F05581CB9A4FEDE4277BA41CDD216CC13FBE691'
    'Vitis_hw_perf/build/Qr_barcode_working_ver0_app.elf' = 'BD1FE37B2E9790269D153EB0C6863F3BEA10047DA60D56256B875464B326ACBF'
}
foreach ($relative in $expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash -ne $expected[$relative]) {
        throw "Verified artifact changed: $relative"
    }
}
$paths = @(
    '.gitignore', 'hardware', 'software', 'tools', 'Docs',
    'Vivado/deps/digilent-vivado-library',
    'Vivado/qr_perf_backup/qr_ip1_bd.bd',
    'Vivado/qr_perf/qr_perf.bit', 'Vivado/qr_perf/qr_perf.xsa',
    'Vivado/qr_perf/qr_perf_bd.tcl',
    'Vivado/qr_perf/timing_summary.rpt', 'Vivado/qr_perf/utilization.rpt',
    'Vivado/qr_perf/cdc.rpt', 'Vivado/qr_perf/cdc_details.rpt',
    'Vivado/qr_perf/bus_skew.rpt', 'Vivado/qr_perf/clocks.rpt',
    'Vivado/build_perf.log',
    'Vivado/qr_perf_sim/tap_test.log', 'Vivado/qr_perf_sim/camera_test.log',
    'Vitis_hw_perf/build/Qr_barcode_working_ver0_app.elf',
    'Vitis_hw_perf/build/compile_commands.json', 'Vitis_hw_perf/build/CMakeCache.txt',
    'Vitis_run/Qr_barcode_working_ver0_app/_ide/psinit/ps7_init.tcl',
    'Vitis_run/qr_verified_platform/export/qr_verified_platform/sw/standalone_ps7_cortexa9_0'
)
$inventory = New-Object 'System.Collections.Generic.List[object]'
New-Item -ItemType Directory -Path $destination | Out-Null
foreach ($relative in $paths) {
    $source = Get-Item -LiteralPath (Join-Path $root $relative)
    $files = if ($source.PSIsContainer) { Get-ChildItem -LiteralPath $source.FullName -File -Recurse -Force } else { @($source) }
    foreach ($file in $files) {
        $fileRelative = $file.FullName.Substring($root.Length + 1)
        $target = Join-Path $destination $fileRelative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $after = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($before -ne $after) { throw "Copy verification failed: $fileRelative" }
        $inventory.Add([pscustomobject]@{path=$fileRelative.Replace('\','/');bytes=$file.Length;sha256=$after})
    }
}
$gitHead = (& git -C $root rev-parse HEAD).Trim()
& git -C $root status --porcelain=v1 | Set-Content -LiteralPath "$destination/git-status.txt" -Encoding UTF8
& git -C $root diff --binary HEAD -- . ':!Vivado' ':!Vitis*' | Set-Content -LiteralPath "$destination/worktree.patch" -Encoding UTF8
[pscustomobject]@{
    version=$Name;created=(Get-Date).ToString('o');workspace=$root;git_head=$gitHead
    git_note='Dirty working tree is preserved as copied files; no commit/tag/reset was performed.'
    toolchain='Vivado/Vitis 2024.2; installed tool binaries are not included.'
    profile='CLKRC=1, XCLK_DIV=2, FCLK0=62.5MHz, -O2, QR_PERF_BLANK_TEST=OFF'
    validation='hardware_final_uart.json: 569/569 PASS, 120.15s; no runtime/overflow/ID/copy-drop errors.'
    restore='Extract into a separate directory; from that root run XSCT tools/run_hardware_perf.tcl. No flash image is included.'
    files=$inventory.ToArray()
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$destination/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $destination -DestinationPath $archive -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
[pscustomobject]@{version=$Name;path=$archive;sha256=$archiveHash;payload_files=$inventory.Count;payload_bytes=($inventory | Measure-Object bytes -Sum).Sum} |
    ConvertTo-Json | Set-Content -LiteralPath "$archive.sha256.json" -Encoding UTF8
Write-Output "SNAPSHOT_VERIFIED $destination"
Write-Output "ARCHIVE $archive"
Write-Output "SHA256 $archiveHash"
Write-Output "FILES $($inventory.Count)"
