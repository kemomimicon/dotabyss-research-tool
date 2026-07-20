param(
    [Parameter(Mandatory=$true)][string]$CaptureDirectory
)

$ErrorActionPreference = "Stop"
if (-not ("IO.Compression.BrotliStream" -as [type])) {
    throw "BrotliStream is unavailable in Windows PowerShell 5. Use PowerShell 7+, or decompress the .br files with a trusted Brotli tool first."
}
$core = Join-Path $CaptureDirectory "core"
$analysis = Join-Path $CaptureDirectory "analysis"
New-Item -ItemType Directory -Force -Path $analysis | Out-Null

foreach ($name in @("WebGL.wasm.br", "WebGL.data.br")) {
    $source = Join-Path $core $name
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing $source" }
    $target = Join-Path $analysis ($name -replace "\.br$", "")
    $input = [IO.File]::OpenRead($source)
    try {
        $brotli = [IO.Compression.BrotliStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [IO.File]::Create($target)
            try { $brotli.CopyTo($output) } finally { $output.Dispose() }
        } finally { $brotli.Dispose() }
    } finally { $input.Dispose() }
    Write-Host "Extracted $target ($((Get-Item -LiteralPath $target).Length) bytes)"
}

& (Join-Path $PSScriptRoot "extract-unitywebdata.ps1") -DataFile (Join-Path $analysis "WebGL.data")
