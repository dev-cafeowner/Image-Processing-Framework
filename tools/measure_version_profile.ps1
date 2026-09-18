param(
    [Parameter(Mandatory=$true)][string]$Profile,
    [int]$Seconds=120,
    [int]$SettleSeconds=15,
    [string]$OutputDirectory='Docs/performance/version_matrix_20260917_1333',
    [string]$Port='COM4'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$catalog=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'version_benchmark_profiles.psd1')
$matches=@($catalog.profiles | Where-Object {$_.id -eq $Profile})
if($matches.Count -ne 1) {throw 'Unknown or ambiguous profile'}
$profileSpec=$matches[0]
$family=$catalog.families[$profileSpec.family]
$bit=if($profileSpec.bit){$profileSpec.bit}else{$family.bit}
$out=Join-Path $root $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null
$rawPath=Join-Path $out "${Profile}_raw.json"
$stdout=Join-Path $out "${Profile}_program_stdout.log"
$stderr=Join-Path $out "${Profile}_program_stderr.log"
foreach($path in @($rawPath,$stdout,$stderr)) {if(Test-Path -LiteralPath $path){throw "Existing evidence: $path"}}
$identities=@(foreach($relative in @($profileSpec.elf,$bit,$family.xsa,$family.runner)) {
    $path=Join-Path $root $relative
    [ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath $path).Hash}
})
$arguments=@($family.runner,$profileSpec.elf)
if($profileSpec.bit){$arguments+=$profileSpec.bit}
$argumentString=(@($arguments | ForEach-Object {'"'+(Join-Path $root $_).Replace('\','/')+'"'}) -join ' ')
$serial=New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$samples=New-Object 'System.Collections.Generic.List[object]'
$started=[DateTimeOffset]::Now
$watch=[Diagnostics.Stopwatch]::StartNew()
$pending='';$programDone=$null;$measureStart=$null;$measureEnd=$null
$outcome='running';$failure=$null;$lastProgress=0.0;$process=$null
try {
    $serial.Open()
    # Drain bytes from the previous firmware before programming the selected one.
    $serial.DiscardInBuffer()
    $process=Start-Process -FilePath 'C:\Xilinx\Vitis\2024.2\bin\xsct.bat' -ArgumentList $argumentString -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    while($true) {
        $pending+=$serial.ReadExisting()
        while($pending.Contains("`n")) {
            $i=$pending.IndexOf("`n")
            $line=$pending.Substring(0,$i).TrimEnd("`r")
            $pending=$pending.Substring($i+1)
            $samples.Add([pscustomobject]@{ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3);text=$line})
            if($line -match 'Stage 6 result: FAIL|^\[FAIL\] (Camera input malformed before capture|Returned PCLK not stably locked)') {
                # Programming normally halts the previous firmware before 5s.
                if($watch.Elapsed.TotalSeconds -gt 5) {$failure=$line}
            }
        }
        if($null -eq $programDone -and $process.HasExited) {
            $process.WaitForExit()
            $programText=(Get-Content -LiteralPath $stdout -Raw)+(Get-Content -LiteralPath $stderr -Raw)
            if($process.ExitCode -ne 0 -or $programText -notmatch 'Running .+ with ' -or $programText -match "couldn't|Cannot connect|no targets|invalid command|Missing .*hardware") {
                $outcome='program_failed';$failure=$programText;break
            }
            $programDone=$watch.Elapsed.TotalMilliseconds
            $measureStart=$programDone+1000*$SettleSeconds
            $measureEnd=$measureStart+1000*$Seconds
            Write-Output "$Profile programmed; settling $SettleSeconds seconds, measuring $Seconds seconds"
        }
        if($failure -and $null -ne $programDone) {$outcome='firmware_failed';break}
        if($null -ne $measureEnd -and $watch.Elapsed.TotalMilliseconds -ge $measureEnd) {$outcome='measured';break}
        if($null -eq $programDone -and $watch.Elapsed.TotalSeconds -gt 90) {
            $outcome='program_timeout';$failure='XSCT exceeded 90s';break
        }
        if($watch.Elapsed.TotalSeconds-$lastProgress -ge 30) {
            $lastProgress=$watch.Elapsed.TotalSeconds
            $latest=@($samples | Where-Object {$_.text -match '^\[SUMMARY\]|^\[PERF\]|^\[QR (PASS|MISS)\]'} | Select-Object -Last 1)
            Write-Output ("{0} elapsed={1:N1}s {2}" -f $Profile,$lastProgress,($latest.text -join ''))
        }
        Start-Sleep -Milliseconds 5
    }
} catch {$outcome='harness_failed';$failure=$_.Exception.Message;throw}
finally {
    if($serial.IsOpen){$serial.Close()};$serial.Dispose()
    [ordered]@{
        profile=$profileSpec;identities=$identities;started=$started.ToString('o');duration_s=$watch.Elapsed.TotalSeconds
        port=$Port;baud=115200;outcome=$outcome;failure=$failure
        program_done_ms=$programDone;measurement_start_ms=$measureStart;measurement_end_ms=$measureEnd
        requested_measurement_seconds=$Seconds;settle_seconds=$SettleSeconds
        note='Host-fixed observation after successful XSCT completion + settling. Summarize only complete firmware windows inside this boundary; earlier firmware/init output is retained but excluded. No JTAG during measurement.'
        samples=$samples.ToArray();trailing_partial_line=$pending
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $rawPath -Encoding UTF8
}
foreach($identity in $identities) {
    if((Get-FileHash -LiteralPath (Join-Path $root $identity.path)).Hash -ne $identity.sha256) {throw 'Artifact changed during measurement'}
}
Write-Output "$Profile outcome=$outcome; evidence=$rawPath"
if($failure){Write-Output $failure}
