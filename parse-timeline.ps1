param(
    [Parameter(Mandatory=$true)][string]$AssetFile,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot "timeline-output" }
$lines = Get-Content -LiteralPath $AssetFile
$actionNames = [Collections.Generic.List[string]]::new()
$inActionNameList = $false
foreach ($line in $lines) {
    if ($line -eq "    m_Keys:") { $inActionNameList = $true; continue }
    if ($inActionNameList -and $line -eq "    m_Values:") { break }
    if ($inActionNameList -and $line -match '^    - (.+)$') { $actionNames.Add($Matches[1]) }
}

$rows = [Collections.Generic.List[object]]::new()
$actionIndex = -1
$variantIndex = 0
$currentKey = $null
$currentType = $null
foreach ($line in $lines) {
    if ($line -match '^    - m_Keys: [0-9a-fA-F]+$') {
        $actionIndex++
        $variantIndex = 0
        continue
    }
    if ($line -match '^      - m_Keys:') {
        $variantIndex++
        $currentKey = $null
        $currentType = $null
        continue
    }
    if ($line -match 'Key:\s*([A-Za-z0-9._-]+)') { $currentKey = $Matches[1]; continue }
    if ($line -match 'TypeName:\s*(.+)$') { $currentType = $Matches[1]; continue }
    if ($line -match 'JsonValue:\s*(.*)$' -and $currentKey) {
        $action = if ($actionIndex -ge 0 -and $actionIndex -lt $actionNames.Count) { $actionNames[$actionIndex] } else { "Action_$actionIndex" }
        $rows.Add([pscustomobject]@{
            Action = $action
            VariantIndex = $variantIndex
            Key = $currentKey
            TypeName = $currentType
            Value = $Matches[1]
        })
        $currentType = $null
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$base = [IO.Path]::GetFileNameWithoutExtension($AssetFile)
$csv = Join-Path $OutputDirectory ($base + ".csv")
$json = Join-Path $OutputDirectory ($base + ".json")
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csv
$rows | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $json
Write-Host "Parsed $($rows.Count) values across $($actionNames.Count) actions."
Write-Host $csv
Write-Host $json
