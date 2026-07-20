param([Parameter(Mandatory=$true)][string]$CaptureDirectory)

$manifestPath = Join-Path $CaptureDirectory "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json not found." }
$items = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$items |
    Group-Object mimeType |
    Sort-Object Count -Descending |
    Select-Object Count, Name |
    Format-Table -AutoSize

Write-Host "`nLikely data/configuration files:"
$items |
    Where-Object { $_.mimeType -match "json|octet-stream|wasm|javascript" -or $_.url -match "master|config|battle|enemy|skill|buff|asset|bundle" } |
    Select-Object status, mimeType, url, file |
    Format-Table -Wrap
