param(
    [string]$AssetsDirectory = "",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference='Stop'
if(-not $AssetsDirectory){$AssetsDirectory=Join-Path $PSScriptRoot '..\..\work\analysis\assetripper-ability-export\ExportedProject\Assets\MonoBehaviour'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'fc-target-output'}
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$actionNames=@{10='ActionNormal';11='SpecialSkill';20='ActionSkill';30='ChainSkill/ForceChain';40='AssaultSkill';50='HpTriggerSkill';60='ModeChange';70='ObstacleAttackSkill';80='DisasterBossSkill';999='None'}
$rangeNames=@{0='All';1='Melee';2='Range'}
$targetNames=@{0='AllBattlers';1='Opponent';2='Friend';3='Self';4='DeadFriend'}
$unitNames=@{0='All';1='Character';2='DefensiveUnit';3='MineEnemy'}
function M($raw,$field){$m=[regex]::Match($raw,"(?m)(?:^|\s)$([regex]::Escape($field)):\s*([^\r\n]+)");if($m.Success){return $m.Groups[1].Value.Trim()}return ''}
$rawRows=[Collections.Generic.List[object]]::new()
foreach($f in Get-ChildItem -LiteralPath $AssetsDirectory -File -Filter 'Skill*.skill_asset*.asset'){
    $raw=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    $id=M $raw '_skillId';$action=M $raw '_actionSkillType';if(-not$id -or -not$action){continue}
    $target=M $raw '_targetType';$unit=M $raw '_unitTargetType';$range=M $raw '_attackRangeType'
    $rawRows.Add([pscustomobject]@{
        SkillId=[long]$id;SkillName=(M $raw '_skillName');ActionSkillType=[int]$action;ActionSkillTypeName=$actionNames[[int]$action]
        AttackRangeType=[int]$range;AttackRangeTypeName=$rangeNames[[int]$range];AttackArea=(M $raw '_attackArea');AttackAreaMax=(M $raw '_attackAreaMax');AttackAreaDepth=(M $raw '_attackAreaDepth')
        TargetType=[int]$target;TargetTypeName=$targetNames[[int]$target];UnitTargetType=[int]$unit;UnitTargetTypeName=$unitNames[[int]$unit]
        IsTargetEnemy=(M $raw '_isTargetEnemy');IsAerialHit=(M $raw '_isAerialHit');ChargePoint=(M $raw '_chargePoint');Interval=(M $raw '_interval')
        ExcludeBattleLine=(M $raw 'excludeBattleLine');ForceInvincible=(M $raw '_forceInvincible');SourceFile=$f.Name
    })
}
$rows=[Collections.Generic.List[object]]::new()
foreach($g in $rawRows|Group-Object SkillId,ActionSkillType,AttackRangeType,TargetType,UnitTargetType,IsTargetEnemy,IsAerialHit,ChargePoint,Interval){
    $x=$g.Group|Select-Object -First 1
    $x|Add-Member NoteProperty DuplicateCount $g.Count
    $rows.Add($x)
}
$rows=$rows|Sort-Object SkillId,ActionSkillType
$rows|Export-Csv -LiteralPath (Join-Path $OutputDirectory 'fc-and-action-skill-targets.csv') -NoTypeInformation -Encoding UTF8
$rows|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'fc-and-action-skill-targets.json') -Encoding UTF8
$fc=@($rows|Where-Object ActionSkillType -eq 30)
$fc|Export-Csv -LiteralPath (Join-Path $OutputDirectory 'force-chain-targets.csv') -NoTypeInformation -Encoding UTF8
$fc|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'force-chain-targets.json') -Encoding UTF8
Write-Host "Parsed $($rows.Count) unique action/chain skill assets; ForceChain=$($fc.Count)."
Write-Host "Output: $((Resolve-Path $OutputDirectory).Path)"
