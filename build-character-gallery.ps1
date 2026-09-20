param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$CharacterCatalogAsset,
    [string]$OutputDirectory = "",
    [string]$NormalAttackCsv = ""
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'character-gallery' }
if (-not $NormalAttackCsv) { $NormalAttackCsv = Join-Path $PSScriptRoot 'normal-attack-output\normal-attacks-summary.csv' }
$imageDirectory = Join-Path $OutputDirectory 'images'
New-Item -ItemType Directory -Force -Path $imageDirectory | Out-Null

$rows = foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File -Filter '*.png') {
    $id = if ($file.BaseName -match '([0-9]{9}G)') { $Matches[1] } else { '' }
    if (-not $id) { continue }
    $category = if ($file.BaseName -match '^CharaCutin') { 'cutin' }
        elseif ($file.BaseName -match '^CharaIcon') { 'stat' }
        elseif ($file.BaseName -match 'Gacha') { 'gacha' }
        elseif ($file.BaseName -match '_L_') { 'large' }
        elseif ($file.BaseName -match '_M_') { 'medium' }
        elseif ($file.BaseName -match '^Prize_') { 'prize' }
        else { 'other' }
    $destination = Join-Path $imageDirectory $file.Name
    if ([IO.Path]::GetFullPath($file.FullName) -ne [IO.Path]::GetFullPath($destination)) {
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    [pscustomobject]@{ CharacterId=$id; Category=$category; FileName=$file.Name; Bytes=$file.Length }
}
$rows | Sort-Object CharacterId,Category | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'image-map.csv') -NoTypeInformation -Encoding UTF8

$catalogIds = Select-String -LiteralPath $CharacterCatalogAsset -Pattern '^    - ([0-9]{9}G)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
$coveredIds = @($rows.CharacterId | Sort-Object -Unique)
$missing = @($catalogIds | Where-Object { $_ -notin $coveredIds })
$missing | ForEach-Object { [pscustomobject]@{CharacterId=$_; Reason='No matching normal-version PNG bundle in captured resource catalog'} } |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory 'missing-images.csv') -NoTypeInformation -Encoding UTF8

function Html([string]$value) { [Net.WebUtility]::HtmlEncode($value) }
$normalById = @{}
if (Test-Path -LiteralPath $NormalAttackCsv) {
    foreach ($normal in (Import-Csv -LiteralPath $NormalAttackCsv)) { $normalById[$normal.CharacterId] = $normal }
}
$cards = foreach ($group in ($rows | Group-Object CharacterId | Sort-Object Name)) {
    $id = $group.Name
    $items = @($group.Group)
    $preferred = @($items | Sort-Object @{Expression={switch($_.Category){'large'{0}'stat'{1}'gacha'{2}'cutin'{3}default{4}}}},FileName)[0]
    $links = ($items | Sort-Object Category,FileName | ForEach-Object {
        '<a href="images/{0}" target="_blank">{1}</a>' -f (Html $_.FileName),(Html $_.Category)
    }) -join ' · '
    $skill = '../character-timeline-output/CharacterTimelineEffectValueAsset_{0}.csv' -f $id
    $normalHtml = if ($normalById.ContainsKey($id)) {
        $normal = $normalById[$id]
        $basis = switch ($normal.TimingBasis) {
            'direct_hit' { 'direct hit time' }
            'projectile_launch' { 'projectile launch time (not landing time)' }
            'mixed_hit_and_projectile_launch' { 'mixed direct-hit and projectile-launch time' }
            default { 'no combat hit event' }
        }
        '<p class="normal"><b>Normal attack:</b> {0}<br>Cycle: {1}s; events: {2}<br>{3}: {4}</p>' -f `
            (Html $normal.NormalSkillName),(Html $normal.IntervalSeconds),(Html $normal.ObservedHitEventCount),(Html $basis),(Html $normal.ObservedEventTimes)
    } else { '<p class="normal muted">No matching normal-attack resource.</p>' }
    @"
<article class="card" data-id="$id">
  <a href="images/$(Html $preferred.FileName)" target="_blank"><img loading="lazy" src="images/$(Html $preferred.FileName)" alt="$id"></a>
  <h2>$id</h2>
  <p>$links</p>
  $normalHtml
  <p><a href="$skill">Skill data CSV</a></p>
</article>
"@
}
$missingHtml = if ($missing.Count) { ($missing | ForEach-Object { '<code>{0}</code>' -f (Html $_) }) -join ' ' } else { 'None' }
$html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DotAbyss Character ID Gallery</title><style>
body{font-family:system-ui,sans-serif;margin:24px;background:#111827;color:#e5e7eb}a{color:#7dd3fc}input{width:min(520px,90%);padding:10px;margin:8px 0 20px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px}.card{background:#1f2937;padding:12px;border-radius:10px}.card img{width:100%;height:230px;object-fit:contain;background:#0b1020}.card h2{font-size:16px;margin:8px 0}.card p{font-size:13px;line-height:1.55}.normal{border-top:1px solid #374151;border-bottom:1px solid #374151;padding:8px 0}.muted{color:#9ca3af}.missing{margin:24px 0;line-height:2}code{background:#374151;padding:3px 5px;border-radius:4px}
</style></head><body><h1>DotAbyss Character ID Gallery</h1>
<p>$(($coveredIds).Count) character IDs and $($rows.Count) images. Normal-attack events are linked by character ID. Ranged timing is projectile launch time, not actual landing time.</p>
<input id="q" placeholder="Example: 102901000G"><div class="grid">$($cards -join "`n")</div>
<section class="missing"><h2>Timeline IDs without a captured image ($($missing.Count))</h2><p>$missingHtml</p></section>
<script>const q=document.querySelector('#q');q.addEventListener('input',()=>{const s=q.value.trim().toUpperCase();document.querySelectorAll('.card').forEach(x=>x.hidden=!x.dataset.id.includes(s))});</script>
</body></html>
"@
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'gallery.html'),$html,[Text.UTF8Encoding]::new($false))
Write-Host "Gallery: $($coveredIds.Count) IDs, $($rows.Count) images, $($missing.Count) missing IDs."
