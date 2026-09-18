param([string]$OutputDirectory='Docs/performance/version_matrix_20260917_1333')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$catalog=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'version_benchmark_profiles.psd1')
$out=Join-Path $root $OutputDirectory
$finishedSelectedProfile=$false
# Files already present are not repeated or overwritten. A partial run requires
# operator inspection before resuming; only complete summary+raw pairs are skipped.
try {
    foreach($profileSpec in $catalog.profiles) {
        $raw=Join-Path $out "$($profileSpec.id)_raw.json"
        $summary=Join-Path $out "$($profileSpec.id)_summary.json"
        if((Test-Path -LiteralPath $raw) -and (Test-Path -LiteralPath $summary)) {
            Write-Output "PRESERVED $($profileSpec.id)";continue
        }
        if(Test-Path -LiteralPath $raw){throw "Unsummarized evidence needs inspection: $raw"}
        & "$PSScriptRoot/measure_version_profile.ps1" -Profile $profileSpec.id -OutputDirectory $OutputDirectory
        & "$PSScriptRoot/summarize_version_profile.ps1" -Path $raw
        if($profileSpec.id -eq 'stage4') {
            $last=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
            $finishedSelectedProfile=$last.outcome -eq 'measured' -and $last.error_samples -eq 0 -and $last.qr_pass -gt 0
        }
    }
} finally {
    # Restore the current selected profile even when an old firmware/parser fails.
    # This is volatile FPGA/PS programming, never flash/SD modification.
    if($finishedSelectedProfile) {
        Write-Output 'Leaving the successfully measured Stage4 profile running (no extra reset).'
    } else {
        $restore=Join-Path $out ('restore_stage4_'+(Get-Date -Format 'HHmmss')+'.log')
        & 'C:\Xilinx\Vitis\2024.2\bin\xsct.bat' "$PSScriptRoot/run_video30_stage4.tcl" 2>&1 | Tee-Object -FilePath $restore
        if($LASTEXITCODE -ne 0){Write-Warning 'Restore failed: inspect the recorded XSCT output'}
    }
}
