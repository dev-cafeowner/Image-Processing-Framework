param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$blocks=New-Object 'System.Collections.Generic.List[object]'
$block=New-Object 'System.Collections.Generic.List[object]'
foreach($sample in $raw.samples) {
    $block.Add($sample)
    if($sample.text -match '^\[RENDER\]') {
        $complete=$true
        foreach($kind in @('VIDEO','CAM3','RXCLK','SUMMARY','DECODE','RENDER')) {
            if(@($block | Where-Object {$_.text -match "^\[$kind\]"}).Count -ne 1) {$complete=$false}
        }
        if($complete) {$blocks.Add(@($block.ToArray()))}
        $block.Clear()
    }
}
if($blocks.Count -lt 3) {throw 'Insufficient common measurement blocks'}
# First block may include device time before host capture. Last incomplete
# block is omitted. All four summary parsers now analyze identical windows.
$selected=@($blocks | Select-Object -Skip 1 | ForEach-Object {$_})
$output=$Path -replace '\.json$','_selected.json'
if($output -eq $Path) {throw 'Expected JSON capture'}
[ordered]@{source=$Path;started=$raw.started;duration_s=$raw.duration_s;selection='Common VIDEO/CAM3/RXCLK/SUMMARY/DECODE/RENDER blocks; initial block and final incomplete block excluded';samples=$selected} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $output -Encoding UTF8
"Selected $($blocks.Count-1) common complete blocks: $output"
