param(
    [int]$Seconds = 40,
    [string]$Port = 'COM4',
    [string]$Output = 'Docs/performance/software_uart.json'
)
$ErrorActionPreference = 'Stop'
$serial = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$serial.ReadTimeout = 100
$samples = New-Object 'System.Collections.Generic.List[object]'
$watch = [Diagnostics.Stopwatch]::StartNew()
$pending = ''
try {
    $serial.Open()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $pending += $serial.ReadExisting()
        while ($pending.Contains("`n")) {
            $index = $pending.IndexOf("`n")
            $line = $pending.Substring(0,$index).TrimEnd("`r")
            $pending = $pending.Substring($index+1)
            $samples.Add([pscustomobject]@{ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3);text=$line})
            if ($line -match '\[PERF\]|\[SUMMARY\]|\[VIDEO\]|\[QR PASS\]|\[QR MISS\]|\[FAIL\]|\[WARN\]') { Write-Output $line }
        }
        Start-Sleep -Milliseconds 5
    }
} finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
    $parent = Split-Path -Parent $Output
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [pscustomobject]@{started=(Get-Date).AddMilliseconds(-$watch.Elapsed.TotalMilliseconds).ToString('o');duration_s=$watch.Elapsed.TotalSeconds;port=$Port;baud=115200;samples=$samples.ToArray()} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output -Encoding UTF8
}
Write-Output "Saved $($samples.Count) lines to $Output"
