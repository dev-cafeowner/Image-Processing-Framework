param([string]$OutputDirectory='Docs/performance/version_matrix_20260917_1333/final_retests')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root $OutputDirectory
$selectedRunning=$false
# Run only after the main suite has released COM4 and JTAG.
try {
    foreach($id in @('stage1_legacy','stage4')) {
        $raw=Join-Path $out "${id}_raw.json"
        $summary=Join-Path $out "${id}_summary.json"
        if((Test-Path -LiteralPath $raw) -and (Test-Path -LiteralPath $summary)) {
            Write-Output "PRESERVED retest $id";continue
        }
        if(Test-Path -LiteralPath $raw){throw "Unsummarized retest evidence: $raw"}
        & "$PSScriptRoot/measure_version_profile.ps1" -Profile $id -OutputDirectory $OutputDirectory
        & "$PSScriptRoot/summarize_version_profile.ps1" -Path $raw
        if($id -eq 'stage4') {
            $result=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
            $selectedRunning=$result.outcome -eq 'measured' -and $result.error_samples -eq 0 -and $result.qr_pass -gt 0 -and !$result.details.progress_warning
        }
    }
} finally {
    if($selectedRunning) {
        Write-Output 'Final Stage4 reference completed; leaving this measured boot running.'
    } else {
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $restore=Join-Path $out ('restore_stage4_'+(Get-Date -Format 'HHmmss')+'.log')
        & 'C:\Xilinx\Vitis\2024.2\bin\xsct.bat' "$PSScriptRoot/run_video30_stage4.tcl" 2>&1 | Tee-Object -FilePath $restore
        if($LASTEXITCODE -ne 0){Write-Warning 'Restore failed; inspect XSCT output'}
    }
}
