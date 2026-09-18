param(
    [string]$Xsct = 'C:/Xilinx/Vitis/2024.2/bin/xsct.bat',
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release/manifest.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.files) {
    $path = [IO.Path]::GetFullPath((Join-Path $packageRoot $entry.path))
    if (!$path.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe manifest path: $($entry.path)"
    }
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {throw "Missing payload: $($entry.path)"}
    if ((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
        throw "Release integrity failure: $($entry.path)"
    }
}
Write-Output "Verified $($manifest.files.Count) payloads for $($manifest.tag)."
if ($VerifyOnly) {exit 0}
if (!(Test-Path -LiteralPath $Xsct -PathType Leaf)) {throw "XSCT not found: $Xsct"}
Write-Output 'Resetting the connected Zynq PS and programming PL/ELF through JTAG (RAM only).'
& $Xsct (Join-Path $packageRoot 'run.tcl')
if ($LASTEXITCODE -ne 0) {throw "XSCT failed with exit code $LASTEXITCODE"}
