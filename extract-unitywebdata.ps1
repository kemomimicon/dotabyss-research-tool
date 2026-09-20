param(
    [Parameter(Mandatory=$true)][string]$DataFile,
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $DataFile) "unitywebdata")
)

$ErrorActionPreference = "Stop"
$signature = [Text.Encoding]::ASCII.GetBytes("UnityWebData1.0`0")
$input = [IO.File]::OpenRead((Resolve-Path $DataFile))
try {
    $reader = [IO.BinaryReader]::new($input, [Text.Encoding]::UTF8, $true)
    $actual = $reader.ReadBytes($signature.Length)
    if ([Text.Encoding]::ASCII.GetString($actual) -ne "UnityWebData1.0`0") { throw "Not a UnityWebData1.0 archive." }
    $headerSize = $reader.ReadUInt32()
    $entries = @()
    while ($input.Position -lt $headerSize) {
        $offset = $reader.ReadUInt32()
        $size = $reader.ReadUInt32()
        $pathLength = $reader.ReadUInt32()
        $path = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($pathLength))
        $entries += [pscustomobject]@{ Path=$path; Offset=$offset; Size=$size }
    }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $buffer = New-Object byte[] (1MB)
    foreach ($entry in $entries) {
        $target = Join-Path $OutputDirectory ($entry.Path -replace "/", [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $input.Position = $entry.Offset
        $output = [IO.File]::Create($target)
        try {
            [long]$remaining = $entry.Size
            while ($remaining -gt 0) {
                $count = $input.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
                if ($count -le 0) { throw "Unexpected end of archive while extracting $($entry.Path)." }
                $output.Write($buffer, 0, $count)
                $remaining -= $count
            }
        } finally { $output.Dispose() }
        Write-Host "Extracted $($entry.Path) ($($entry.Size) bytes)"
    }
} finally { $input.Dispose() }
