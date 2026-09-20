param(
    [Parameter(Mandatory=$true)][string]$AssetFile,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot "character-timeline-output" }
$lines = Get-Content -LiteralPath $AssetFile
$characterId = if ((Split-Path $AssetFile -Leaf) -match 'CharacterTimelineEffectValueAsset_([0-9A-Za-z]+)') { $Matches[1] } else { '' }

$sectionIds = @{}
$scanSection = $null
foreach ($line in $lines) {
    if ($line -match '^  _([A-Za-z]+SkillValues):') { $scanSection = $Matches[1]; continue }
    if ($scanSection -and $line -match '^    m_Keys: ([0-9a-fA-F]+)$') {
        $hex = $Matches[1]
        $ids = @()
        for ($i=0; $i + 8 -le $hex.Length; $i += 8) {
            $chunk = $hex.Substring($i,8)
            $bytes = [byte[]]@(
                [Convert]::ToByte($chunk.Substring(0,2),16),
                [Convert]::ToByte($chunk.Substring(2,2),16),
                [Convert]::ToByte($chunk.Substring(4,2),16),
                [Convert]::ToByte($chunk.Substring(6,2),16)
            )
            $ids += [BitConverter]::ToInt32($bytes,0)
        }
        $sectionIds[$scanSection] = $ids
    }
}

$rows = [Collections.Generic.List[object]]::new()
$actionIndex = -1
$section = $null
$currentKey = $null
$currentType = $null
$effectIndex = 0
foreach ($line in $lines) {
    if ($line -match '^  _([A-Za-z]+SkillValues):') {
        $section = $Matches[1]
        $actionIndex = -1
        continue
    }
    if ($line -match '^    - m_Keys:') {
        $actionIndex++
        $currentKey = $null
        continue
    }
    if ($line -match 'Key:\s*([A-Za-z0-9._-]+)') {
        $currentKey = $Matches[1]
        $effectIndex = 0
        continue
    }
    if ($line -match '^        Values:') { $effectIndex = 0; continue }
    if ($line -match '^        - TypeName:\s*(.+)$') { $currentType = $Matches[1]; continue }
    if ($line -match '^          JsonValue:\s*(.*)$' -and $currentKey) {
        $effectIndex++
        $ids = $sectionIds[$section]
        $actionId = if ($actionIndex -ge 0 -and $actionIndex -lt $ids.Count) { $ids[$actionIndex] } else { $actionIndex + 1 }
        $rows.Add([pscustomobject]@{
            CharacterId = $characterId
            SkillType = $section
            SkillLevel = $actionId
            EffectIndex = $effectIndex
            Key = $currentKey
            TypeName = $currentType
            Value = $Matches[1]
        })
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$base = [IO.Path]::GetFileNameWithoutExtension($AssetFile)
$csv = Join-Path $OutputDirectory ($base + '.csv')
$json = Join-Path $OutputDirectory ($base + '.json')
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $json -Encoding UTF8
Write-Host "Parsed $($rows.Count) values across $($sectionIds.Keys.Count) skill sections."
