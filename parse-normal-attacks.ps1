param(
    [Parameter(Mandatory=$true)][string]$ExportDirectory,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'normal-attack-output' }
$assets = Join-Path $ExportDirectory 'ExportedProject\Assets'
if (-not (Test-Path -LiteralPath $assets)) { throw "ExportedProject/Assets not found under $ExportDirectory" }

function Read-AllText([string]$path) {
    [IO.File]::ReadAllText($path)
}

# AssetRipper assigns a unique Unity GUID to every exported object. Build a map
# once so character prefabs can be followed through skill assets and timelines.
$guidToPath = @{}
$metaFiles = Get-ChildItem -LiteralPath $assets -Recurse -File -Filter '*.meta'
foreach ($meta in $metaFiles) {
    $reader = [IO.File]::OpenText($meta.FullName)
    try {
        for ($i = 0; $i -lt 12 -and -not $reader.EndOfStream; $i++) {
            $line = $reader.ReadLine()
            if ($line -match '^guid:\s*([0-9a-f]{32})') {
                $guidToPath[$Matches[1]] = $meta.FullName.Substring(0, $meta.FullName.Length - 5)
                break
            }
        }
    } finally { $reader.Dispose() }
}

function Resolve-Guid([string]$guid) {
    if ($guidToPath.ContainsKey($guid)) { return $guidToPath[$guid] }
    return $null
}

function Get-Field([string]$text, [string]$name) {
    $m = [regex]::Match($text, "(?m)^\s*${name}:\s*(.*?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-PlayableGuidForObject([string]$prefabText, [string]$objectName) {
    $blocks = [regex]::Matches($prefabText, '(?ms)^--- !u!([0-9]+) &([0-9]+)\r?\n(.*?)(?=^--- !u!|\z)')
    $goId = $null
    foreach ($block in $blocks) {
        if ($block.Groups[1].Value -eq '1' -and $block.Groups[3].Value -match "(?m)^\s*m_Name:\s*$([regex]::Escape($objectName))\s*$") {
            $goId = $block.Groups[2].Value
            break
        }
    }
    if (-not $goId) { return $null }
    foreach ($block in $blocks) {
        if ($block.Groups[1].Value -ne '320') { continue }
        $body = $block.Groups[3].Value
        if ($body -notmatch "(?m)^\s*m_GameObject:\s*\{fileID:\s*$goId\}\s*$") { continue }
        $m = [regex]::Match($body, '(?m)^\s*m_PlayableAsset:\s*\{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function Get-TimelineInfo([string]$timelinePath) {
    $result = [ordered]@{ Duration = 0.0; DamageTimes = @(); HitCheckTimes = @(); TrackNames = @(); FireClips = @() }
    if (-not $timelinePath -or -not (Test-Path -LiteralPath $timelinePath)) { return [pscustomobject]$result }
    $timelineText = Read-AllText $timelinePath
    $trackGuids = [regex]::Matches($timelineText, '(?m)^\s*- \{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),') | ForEach-Object { $_.Groups[1].Value }
    $pendingTracks = [Collections.Generic.Queue[string]]::new()
    foreach ($trackGuid in $trackGuids) { $pendingTracks.Enqueue($trackGuid) }
    $visitedTracks = @{}
    while ($pendingTracks.Count -gt 0) {
        $trackGuid = $pendingTracks.Dequeue()
        if ($visitedTracks.ContainsKey($trackGuid)) { continue }
        $visitedTracks[$trackGuid] = $true
        $trackPath = Resolve-Guid $trackGuid
        if (-not $trackPath -or -not (Test-Path -LiteralPath $trackPath)) { continue }
        $trackText = Read-AllText $trackPath
        $trackName = Get-Field $trackText 'm_Name'
        if ($trackName) { $result.TrackNames += $trackName }
        # Group tracks such as ActionSkill may contain the actual hit tracks as
        # children rather than timeline-root tracks.
        $childGuids = [regex]::Matches($trackText, '(?m)^\s*- \{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),') | ForEach-Object { $_.Groups[1].Value }
        foreach ($childGuid in $childGuids) { $pendingTracks.Enqueue($childGuid) }
        $starts = [regex]::Matches($trackText, '(?m)^\s*m_Start:\s*([-+0-9.eE]+)\s*$') | ForEach-Object { [double]$_.Groups[1].Value }
        $durations = [regex]::Matches($trackText, '(?m)^\s*m_Duration:\s*([-+0-9.eE]+)\s*$') | ForEach-Object { [double]$_.Groups[1].Value }
        for ($i=0; $i -lt $starts.Count; $i++) {
            $end = $starts[$i] + $(if ($i -lt $durations.Count) { $durations[$i] } else { 0 })
            if ($end -gt $result.Duration) { $result.Duration = $end }
        }
        if ($trackName -match 'Hit Damage') { $result.DamageTimes += $starts }
        if ($trackName -match 'Hit Check') { $result.HitCheckTimes += $starts }
        if ($trackName -match 'Fire Skill') {
            $clipGuids = [regex]::Matches($trackText, '(?m)^\s*m_Asset:\s*\{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),') | ForEach-Object { $_.Groups[1].Value }
            for ($i=0; $i -lt $clipGuids.Count; $i++) {
                $result.FireClips += [pscustomobject]@{ Guid=$clipGuids[$i]; Start=$(if($i -lt $starts.Count){$starts[$i]}else{0}) }
            }
        }
    }
    [pscustomobject]$result
}

$rows = [Collections.Generic.List[object]]::new()
$unitPrefabs = Get-ChildItem -LiteralPath $assets -File -Filter 'Unit*.prefab' | Where-Object { $_.BaseName -match '^Unit(1[0-9]+G)$' }
foreach ($unit in $unitPrefabs) {
    $characterId = [regex]::Match($unit.BaseName, '^Unit(1[0-9]+G)$').Groups[1].Value
    $text = Read-AllText $unit.FullName

    $normalGuidMatch = [regex]::Match($text, '(?m)^\s*_actionNormal:\s*\{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),')
    $normalPath = if ($normalGuidMatch.Success) { Resolve-Guid $normalGuidMatch.Groups[1].Value } else { $null }
    $normalText = if ($normalPath) { Read-AllText $normalPath } else { '' }

    # Most units use a child AttackSkillEffect timeline. Newer/special units put
    # the hit logic directly on Attack, so use it as a fallback.
    $attackEffectGuid = Get-PlayableGuidForObject $text 'AttackSkillEffect'
    $effectSource = 'AttackSkillEffect'
    if (-not $attackEffectGuid) { $attackEffectGuid = Get-PlayableGuidForObject $text 'Attack'; $effectSource = 'Attack' }
    $attackEffectPath = if ($attackEffectGuid) { Resolve-Guid $attackEffectGuid } else { $null }
    $timeline = Get-TimelineInfo $attackEffectPath

    $damageTimes = @($timeline.DamageTimes | Sort-Object)
    $hitTimes = @($timeline.HitCheckTimes | Sort-Object)
    $projectileDamageCount = 0
    $projectileLandingTimes = @()
    $projectileNames = @()
    $fireTimes = @($timeline.FireClips | ForEach-Object {$_.Start} | Sort-Object)
    foreach ($fire in $timeline.FireClips) {
        $clipPath = Resolve-Guid $fire.Guid
        if (-not $clipPath) { continue }
        $clipText = Read-AllText $clipPath
        $projectileGuid = $null
        $direct = [regex]::Match($clipText, '(?m)^\s*throwPrefab:\s*\{fileID:\s*(?!0\})[^,]+, guid:\s*([0-9a-f]{32}),')
        if ($direct.Success -and $direct.Groups[1].Value -ne '0000000deadbeef15deadf00d0000000') {
            $projectileGuid = $direct.Groups[1].Value
        } else {
            $container = [regex]::Match($clipText, '(?m)^\s*projectileElementContainer:\s*\{fileID:\s*11400000, guid:\s*([0-9a-f]{32}),')
            if ($container.Success) {
                $containerPath = Resolve-Guid $container.Groups[1].Value
                if ($containerPath) {
                    $containerText = Read-AllText $containerPath
                    $assetGuid = [regex]::Match($containerText, '(?m)^\s*m_AssetGUID:\s*([0-9a-f]{32})\s*$')
                    if ($assetGuid.Success) { $projectileGuid = $assetGuid.Groups[1].Value }
                }
            }
        }
        $projectilePath = if ($projectileGuid) { Resolve-Guid $projectileGuid } else { $null }
        if (-not $projectilePath -or -not (Test-Path -LiteralPath $projectilePath)) { continue }
        $projectileNames += Split-Path $projectilePath -Leaf
        $projectileText = Read-AllText $projectilePath
        $shotNumberValue = Get-Field $projectileText '_shootNumber'
        $shotNumber = if ($shotNumberValue -match '^\d+$' -and [int]$shotNumberValue -gt 0) { [int]$shotNumberValue } else { 1 }
        $landingGuid = Get-PlayableGuidForObject $projectileText 'OnLanding'
        $landingPath = if ($landingGuid) { Resolve-Guid $landingGuid } else { $null }
        $landing = Get-TimelineInfo $landingPath
        $projectileDamageCount += $landing.DamageTimes.Count * $shotNumber
        foreach ($t in $landing.DamageTimes) { for($n=0;$n -lt $shotNumber;$n++){ $projectileLandingTimes += ($fire.Start + $t) } }
    }
    $observedTimes = @($damageTimes + $fireTimes | Sort-Object)
    $timingBasis = if ($damageTimes.Count -gt 0 -and $fireTimes.Count -gt 0) {
        'mixed_hit_and_projectile_launch'
    } elseif ($damageTimes.Count -gt 0) {
        'direct_hit'
    } elseif ($fireTimes.Count -gt 0) {
        'projectile_launch'
    } elseif ($timeline.TrackNames -match '^ActionSkill$') {
        'delegated_action_skill_unresolved'
    } else {
        'none'
    }
    $rows.Add([pscustomobject]@{
        CharacterId = $characterId
        NormalSkillId = Get-Field $normalText '_skillId'
        NormalSkillName = Get-Field $normalText '_skillName'
        IntervalSeconds = Get-Field $normalText '_interval'
        ChargePoint = Get-Field $normalText '_chargePoint'
        AttackRangeType = Get-Field $normalText '_attackRangeType'
        AttackAreaMax = Get-Field $normalText '_attackAreaMax'
        AttackAreaDepth = Get-Field $normalText '_attackAreaDepth'
        DirectDamageEventCount = $damageTimes.Count
        DirectDamageTimes = ($damageTimes | ForEach-Object { $_.ToString('0.######') }) -join '|'
        HitCheckEventCount = $hitTimes.Count
        HitCheckTimes = ($hitTimes | ForEach-Object { $_.ToString('0.######') }) -join '|'
        TimelineDurationSeconds = [math]::Round($timeline.Duration, 6)
        FireEventCount = $fireTimes.Count
        FireTimes = ($fireTimes | ForEach-Object { $_.ToString('0.######') }) -join '|'
        ObservedHitEventCount = $damageTimes.Count + $fireTimes.Count
        ObservedEventTimes = ($observedTimes | ForEach-Object { $_.ToString('0.######') }) -join '|'
        TimingBasis = $timingBasis
        ProjectileDamageEventCount = $projectileDamageCount
        ProjectileLandingTimes = ($projectileLandingTimes | Sort-Object | ForEach-Object { $_.ToString('0.######') }) -join '|'
        TotalDamageEventCount = $damageTimes.Count + $projectileDamageCount
        HasProjectileTrack = [bool]($timeline.TrackNames -match 'Fire Skill')
        ProjectileAssets = ($projectileNames | Sort-Object -Unique) -join '|'
        TimelineTracks = ($timeline.TrackNames | Sort-Object -Unique) -join '|'
        NormalSkillAsset = if ($normalPath) { Split-Path $normalPath -Leaf } else { '' }
        AttackEffectAsset = if ($attackEffectPath) { Split-Path $attackEffectPath -Leaf } else { '' }
        AttackEffectSource = $effectSource
    })
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$csv = Join-Path $OutputDirectory 'normal-attacks-summary.csv'
$json = Join-Path $OutputDirectory 'normal-attacks-summary.json'
$rows | Sort-Object CharacterId | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$rows | Sort-Object CharacterId | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $json -Encoding UTF8
Write-Host "Parsed $($rows.Count) character normal-attack definitions."
Write-Host $csv
