param(
    [string]$AssetsDirectory = "",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"

if (-not $AssetsDirectory) {
    $AssetsDirectory = Join-Path $PSScriptRoot "..\..\work\analysis\assetripper-ability-export\ExportedProject\Assets"
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot "small-skill-output"
}
$AssetsDirectory = (Resolve-Path -LiteralPath $AssetsDirectory).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Get-ScalarFields {
    param([string]$Path)

    $result = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^  ([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($key -notin @(
                'm_ObjectHideFlags','m_CorrespondingSourceObject','m_PrefabInstance',
                'm_PrefabAsset','m_GameObject','m_Enabled','m_EditorHideFlags','m_Script',
                'm_EditorClassIdentifier','_subAssets'
            )) {
                $result[$key] = $value
            }
        }
        elseif ($line -match '^  ([A-Za-z_][A-Za-z0-9_]*):\s*$') {
            $key = $Matches[1]
            if ($key -notin @('_subAssets')) { $result[$key] = '' }
        }
        elseif ($line -match '^  -\s+(.+)$') {
            # Preserve top-level list values (for example _buffs) in source order.
            $lastKey = @($result.Keys)[-1]
            if ($lastKey) {
                $item = $Matches[1].Trim()
                $result[$lastKey] = if ($result[$lastKey]) { "$($result[$lastKey]);$item" } else { $item }
            }
        }
    }
    return $result
}

function Get-CodeFromName {
    param([string]$Name, [string]$Category)
    $prefix = "AbilitySubAsset_${Category}_"
    $code = if ($Name.StartsWith($prefix)) { $Name.Substring($prefix.Length) } else { $Name }
    # AssetRipper appends _0, _1, ... to colliding file names. It is not game data.
    return ($code -replace '_[0-9]+$', '')
}

$guidToAsset = @{}
foreach ($meta in Get-ChildItem -LiteralPath $AssetsDirectory -Recurse -File -Filter '*.asset.meta') {
    $guidLine = Get-Content -LiteralPath $meta.FullName | Where-Object { $_ -match '^guid:\s*([0-9a-fA-F]+)' } | Select-Object -First 1
    if ($guidLine -and $guidLine -match '^guid:\s*([0-9a-fA-F]+)') {
        $assetPath = $meta.FullName.Substring(0, $meta.FullName.Length - 5)
        $guidToAsset[$Matches[1].ToLowerInvariant()] = $assetPath
    }
}

$detailRows = [Collections.Generic.List[object]]::new()
$summaryRows = [Collections.Generic.List[object]]::new()

$catalogAssets = Get-ChildItem -LiteralPath $AssetsDirectory -Recurse -File -Filter 'AbilityEffectAsset_*.asset' |
    Sort-Object `
        @{ Expression = { if ($_.BaseName -match '([0-9]+)$') { [int64]$Matches[1] } else { [int64]::MaxValue } } },
        @{ Expression = { $_.FullName } }

foreach ($catalogAsset in $catalogAssets) {
    if ($catalogAsset.BaseName -notmatch '^AbilityEffectAsset_([0-9]+)$') { continue }
    $effectAssetId = [int]$Matches[1]
    $refs = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $catalogAsset.FullName) {
        if ($line -match '^  - \{fileID: [^,]+, guid: ([0-9a-fA-F]+),') {
            $refs.Add($Matches[1].ToLowerInvariant())
        }
    }

    $codes = @{ AbilityEffect=@(); AbilityTarget=@(); AbilitySituation=@(); AbilityScope=@(); Unknown=@() }
    for ($index = 0; $index -lt $refs.Count; $index++) {
        $guid = $refs[$index]
        $path = $guidToAsset[$guid]
        if (-not $path) {
            $detailRows.Add([pscustomobject]@{
                AbilityEffectAssetId=$effectAssetId; SubAssetIndex=$index + 1; Category='Missing'
                Code=''; AssetName=''; Guid=$guid; ParametersJson='{}'; SourcePath=''
            })
            continue
        }

        $fields = Get-ScalarFields -Path $path
        $name = [string]$fields['m_Name']
        $category = 'Unknown'
        foreach ($candidate in @('AbilityEffect','AbilityTarget','AbilitySituation','AbilityScope')) {
            if ($name -like "AbilitySubAsset_${candidate}_*") { $category = $candidate; break }
        }
        $code = Get-CodeFromName -Name $name -Category $category
        $codes[$category] += $code
        $fields.Remove('m_Name')

        $detailRows.Add([pscustomobject]@{
            AbilityEffectAssetId = $effectAssetId
            SubAssetIndex = $index + 1
            Category = $category
            Code = $code
            AssetName = $name
            Guid = $guid
            ParametersJson = ($fields | ConvertTo-Json -Compress -Depth 8)
            SourcePath = $path.Substring($AssetsDirectory.Length).TrimStart('\')
        })
    }

    $summaryRows.Add([pscustomobject]@{
        AbilityEffectAssetId = $effectAssetId
        EffectCode = ($codes.AbilityEffect -join ';')
        TargetCode = ($codes.AbilityTarget -join ';')
        SituationCode = ($codes.AbilitySituation -join ';')
        ScopeCode = ($codes.AbilityScope -join ';')
        SubAssetCount = $refs.Count
    })
}

$detailCsv = Join-Path $OutputDirectory 'ability-effect-subassets.csv'
$detailJson = Join-Path $OutputDirectory 'ability-effect-subassets.json'
$summaryCsv = Join-Path $OutputDirectory 'ability-effect-assets.csv'
$summaryJson = Join-Path $OutputDirectory 'ability-effect-assets.json'

$detailRows | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding UTF8
$detailRows | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $detailJson -Encoding UTF8
$summaryRows | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8
$summaryRows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

$categoryCounts = $detailRows | Group-Object Category | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "Parsed $($summaryRows.Count) AbilityEffectAssets and $($detailRows.Count) subassets."
Write-Host ($categoryCounts -join ', ')
Write-Host "Output: $((Resolve-Path -LiteralPath $OutputDirectory).Path)"
