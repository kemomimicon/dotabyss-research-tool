param(
    [Parameter(Mandatory=$true)][string]$MasterFile,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'small-skill-output' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Read-U16BE($r) { $b=$r.ReadBytes(2); [Array]::Reverse($b); return [BitConverter]::ToUInt16($b,0) }
function Read-I16BE($r) { $b=$r.ReadBytes(2); [Array]::Reverse($b); return [BitConverter]::ToInt16($b,0) }
function Read-U32BE($r) { $b=$r.ReadBytes(4); [Array]::Reverse($b); return [BitConverter]::ToUInt32($b,0) }
function Read-I32BE($r) { $b=$r.ReadBytes(4); [Array]::Reverse($b); return [BitConverter]::ToInt32($b,0) }
function Read-U64BE($r) { $b=$r.ReadBytes(8); [Array]::Reverse($b); return [BitConverter]::ToUInt64($b,0) }
function Read-I64BE($r) { $b=$r.ReadBytes(8); [Array]::Reverse($b); return [BitConverter]::ToInt64($b,0) }
function Read-Text($r,[int]$n) { return [Text.Encoding]::UTF8.GetString($r.ReadBytes($n)) }

function Read-MpValue {
    param([IO.BinaryReader]$Reader)
    $c=$Reader.ReadByte()
    if($c -le 0x7f){return [long]$c}
    if($c -ge 0xe0){return [long][sbyte]$c}
    if(($c -band 0xf0) -eq 0x80){$n=$c -band 0x0f;$h=[ordered]@{};for($i=0;$i-lt$n;$i++){$k=[string](Read-MpValue $Reader);$h[$k]=Read-MpValue $Reader};return $h}
    if(($c -band 0xf0) -eq 0x90){$n=$c -band 0x0f;$a=[object[]]::new($n);for($i=0;$i-lt$n;$i++){$a[$i]=Read-MpValue $Reader};return ,$a}
    if(($c -band 0xe0) -eq 0xa0){return Read-Text $Reader ($c -band 0x1f)}
    switch($c){
        0xc0{return $null} 0xc2{return $false} 0xc3{return $true}
        0xc4{$n=$Reader.ReadByte();return ,$Reader.ReadBytes($n)}
        0xc5{$n=Read-U16BE $Reader;return ,$Reader.ReadBytes($n)}
        0xc6{$n=Read-U32BE $Reader;return ,$Reader.ReadBytes([int]$n)}
        0xca{$b=$Reader.ReadBytes(4);[Array]::Reverse($b);return [BitConverter]::ToSingle($b,0)}
        0xcb{$b=$Reader.ReadBytes(8);[Array]::Reverse($b);return [BitConverter]::ToDouble($b,0)}
        0xcc{return [long]$Reader.ReadByte()} 0xcd{return [long](Read-U16BE $Reader)}
        0xce{return [long](Read-U32BE $Reader)} 0xcf{return Read-U64BE $Reader}
        0xd0{return [long]$Reader.ReadSByte()} 0xd1{return [long](Read-I16BE $Reader)}
        0xd2{return [long](Read-I32BE $Reader)} 0xd3{return Read-I64BE $Reader}
        0xd9{$n=$Reader.ReadByte();return Read-Text $Reader $n}
        0xda{$n=Read-U16BE $Reader;return Read-Text $Reader $n}
        0xdb{$n=Read-U32BE $Reader;return Read-Text $Reader ([int]$n)}
        0xdc{$n=Read-U16BE $Reader;$a=[object[]]::new($n);for($i=0;$i-lt$n;$i++){$a[$i]=Read-MpValue $Reader};return ,$a}
        0xdd{$n=Read-U32BE $Reader;$a=[object[]]::new([int]$n);for($i=0;$i-lt$n;$i++){$a[$i]=Read-MpValue $Reader};return ,$a}
        0xde{$n=Read-U16BE $Reader;$h=[ordered]@{};for($i=0;$i-lt$n;$i++){$k=[string](Read-MpValue $Reader);$h[$k]=Read-MpValue $Reader};return $h}
        0xdf{$n=Read-U32BE $Reader;$h=[ordered]@{};for($i=0;$i-lt$n;$i++){$k=[string](Read-MpValue $Reader);$h[$k]=Read-MpValue $Reader};return $h}
        0xd4{$null=$Reader.ReadByte();return ,$Reader.ReadBytes(1)}
        0xd5{$null=$Reader.ReadByte();return ,$Reader.ReadBytes(2)}
        0xd6{$null=$Reader.ReadByte();return ,$Reader.ReadBytes(4)}
        0xd7{$null=$Reader.ReadByte();return ,$Reader.ReadBytes(8)}
        0xd8{$null=$Reader.ReadByte();return ,$Reader.ReadBytes(16)}
        0xc7{$n=$Reader.ReadByte();$null=$Reader.ReadByte();return ,$Reader.ReadBytes($n)}
        0xc8{$n=Read-U16BE $Reader;$null=$Reader.ReadByte();return ,$Reader.ReadBytes($n)}
        0xc9{$n=Read-U32BE $Reader;$null=$Reader.ReadByte();return ,$Reader.ReadBytes([int]$n)}
        default{throw ('Unsupported MessagePack marker 0x{0:X2} at offset {1}' -f $c,($Reader.BaseStream.Position-1))}
    }
}

function Skip-MpValue {
    param([IO.BinaryReader]$Reader)
    $c=$Reader.ReadByte()
    if($c -le 0x7f -or $c -ge 0xe0 -or $c -in @(0xc0,0xc2,0xc3)){return}
    if(($c -band 0xe0) -eq 0xa0){$Reader.BaseStream.Seek(($c -band 0x1f),[IO.SeekOrigin]::Current)|Out-Null;return}
    if(($c -band 0xf0) -eq 0x90){$n=$c -band 0x0f;for($i=0;$i -lt $n;$i++){Skip-MpValue $Reader};return}
    if(($c -band 0xf0) -eq 0x80){$n=$c -band 0x0f;for($i=0;$i -lt $n;$i++){Skip-MpValue $Reader;Skip-MpValue $Reader};return}
    switch($c){
        0xc4{$n=$Reader.ReadByte();$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xc5{$n=Read-U16BE $Reader;$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xc6{$n=Read-U32BE $Reader;$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xca{$Reader.BaseStream.Seek(4,'Current')|Out-Null} 0xcb{$Reader.BaseStream.Seek(8,'Current')|Out-Null}
        0xcc{$Reader.BaseStream.Seek(1,'Current')|Out-Null} 0xcd{$Reader.BaseStream.Seek(2,'Current')|Out-Null}
        0xce{$Reader.BaseStream.Seek(4,'Current')|Out-Null} 0xcf{$Reader.BaseStream.Seek(8,'Current')|Out-Null}
        0xd0{$Reader.BaseStream.Seek(1,'Current')|Out-Null} 0xd1{$Reader.BaseStream.Seek(2,'Current')|Out-Null}
        0xd2{$Reader.BaseStream.Seek(4,'Current')|Out-Null} 0xd3{$Reader.BaseStream.Seek(8,'Current')|Out-Null}
        0xd9{$n=$Reader.ReadByte();$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xda{$n=Read-U16BE $Reader;$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xdb{$n=Read-U32BE $Reader;$Reader.BaseStream.Seek($n,'Current')|Out-Null}
        0xdc{$n=Read-U16BE $Reader;for($i=0;$i-lt$n;$i++){Skip-MpValue $Reader}}
        0xdd{$n=Read-U32BE $Reader;for($i=0;$i-lt$n;$i++){Skip-MpValue $Reader}}
        0xde{$n=Read-U16BE $Reader;for($i=0;$i-lt$n;$i++){Skip-MpValue $Reader;Skip-MpValue $Reader}}
        0xdf{$n=Read-U32BE $Reader;for($i=0;$i-lt$n;$i++){Skip-MpValue $Reader;Skip-MpValue $Reader}}
        0xd4{$Reader.BaseStream.Seek(2,'Current')|Out-Null} 0xd5{$Reader.BaseStream.Seek(3,'Current')|Out-Null}
        0xd6{$Reader.BaseStream.Seek(5,'Current')|Out-Null} 0xd7{$Reader.BaseStream.Seek(9,'Current')|Out-Null}
        0xd8{$Reader.BaseStream.Seek(17,'Current')|Out-Null}
        0xc7{$n=$Reader.ReadByte();$Reader.BaseStream.Seek($n+1,'Current')|Out-Null}
        0xc8{$n=Read-U16BE $Reader;$Reader.BaseStream.Seek($n+1,'Current')|Out-Null}
        0xc9{$n=Read-U32BE $Reader;$Reader.BaseStream.Seek($n+1,'Current')|Out-Null}
        default{throw ('Unsupported MessagePack marker 0x{0:X2} while skipping' -f $c)}
    }
}

function Read-MpMapCount([IO.BinaryReader]$Reader){
    $c=$Reader.ReadByte()
    if(($c -band 0xf0) -eq 0x80){return $c -band 0x0f}
    if($c -eq 0xde){return Read-U16BE $Reader}
    if($c -eq 0xdf){return Read-U32BE $Reader}
    throw ('Expected a MessagePack map at the root, found 0x{0:X2}' -f $c)
}

$schemas=[ordered]@{
    m_character_action_skills=@('id','m_character_id','trigger_type','name','description')
    m_characters=@('id','name','rarity','original_m_character_id','element_type','party_position','weapon_type','armor_type','union_type','attack','defence','hp','move_speed','chain_count','chain_waits','chain_interval','critical_probability','critical_damage_ratio','attack_continuous_probability','avoid_probability','knockback_power','knockback_resist','extra_drop_probability','skill_charge','skill_tag','mana_type','open_at')
    m_character_skins=@('id','m_character_id','type','rarity','name','description','serif','is_default','bonus_bond_point','is_collabo','released_at','asset_id','bg_asset_id','display_order')
    m_character_abilities=@('id','m_character_id','asset_id','name','ability_no','order')
    m_abilities=@('id','ability_no','m_ability_effects_id','ability_awake_level','display_order')
    m_ability_details=@('id','ability_no','ability_awake_level','level','description','awake_description')
    m_ability_effects=@('id','type','value')
    m_ability_effect_types=@('id','name','type','grade','is_shown')
    m_ability_releases=@('id','m_character_ability_id','level','condition_type','condition_value')
}

function Convert-Rows($rows,$columns){
    $out=[Collections.Generic.List[object]]::new()
    foreach($row in @($rows)){
        $o=[ordered]@{}
        for($i=0;$i-lt$columns.Count;$i++){$o[$columns[$i]]=if($i-lt$row.Count){$row[$i]}else{$null}}
        $out.Add([pscustomobject]$o)
    }
    return $out
}

$stream=[IO.File]::OpenRead((Resolve-Path -LiteralPath $MasterFile))
$reader=[IO.BinaryReader]::new($stream)
try{
    $selected=[ordered]@{}
    $rootCount=Read-MpMapCount $reader
    for($i=0;$i-lt$rootCount;$i++){
        $key=[string](Read-MpValue $reader)
        if($schemas.Contains($key)){$selected[$key]=Read-MpValue $reader}else{Skip-MpValue $reader}
    }
}finally{$reader.Dispose()}
$tables=[ordered]@{}
foreach($name in $schemas.Keys){
    $value=$selected[$name]
    if($null -eq $value){$tables[$name]=@();continue}
    $tables[$name]=Convert-Rows $value $schemas[$name]
    $tables[$name]|Export-Csv -LiteralPath (Join-Path $OutputDirectory "$name.csv") -NoTypeInformation -Encoding UTF8
    $tables[$name]|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputDirectory "$name.json") -Encoding UTF8
}

$characters=@{};foreach($x in $tables.m_characters){$characters[[string]$x.id]=$x}
$effects=@{};foreach($x in $tables.m_ability_effects){$effects[[string]$x.id]=$x}
$effectTypes=@{};foreach($x in $tables.m_ability_effect_types){$effectTypes[[string]$x.id]=$x}
$abilitiesByNo=@{};foreach($x in $tables.m_abilities){$k=[string]$x.ability_no;if(-not$abilitiesByNo[$k]){$abilitiesByNo[$k]=@()};$abilitiesByNo[$k]+=$x}
$detailsByNo=@{};foreach($x in $tables.m_ability_details){$k=[string]$x.ability_no;if(-not$detailsByNo[$k]){$detailsByNo[$k]=@()};$detailsByNo[$k]+=$x}
$releasesByAbility=@{};foreach($x in $tables.m_ability_releases){$k=[string]$x.m_character_ability_id;if(-not$releasesByAbility[$k]){$releasesByAbility[$k]=@()};$releasesByAbility[$k]+=$x}

$assetSummary=@{}
$assetCsv=Join-Path $OutputDirectory 'ability-effect-assets.csv'
if(Test-Path -LiteralPath $assetCsv){foreach($x in Import-Csv -LiteralPath $assetCsv){$assetSummary[[string]$x.AbilityEffectAssetId]=$x}}

$long=[Collections.Generic.List[object]]::new()
foreach($ca in ($tables.m_character_abilities|Sort-Object {[long]$_.m_character_id}, {[int]$_.order})){
    $ch=$characters[[string]$ca.m_character_id]
    $releaseRows=@($releasesByAbility[[string]$ca.id])
    $releaseText=if($releaseRows.Count -gt 0 -and $null -ne $releaseRows[0]){
        @($releaseRows|ForEach-Object{"lv=$($_.level),type=$($_.condition_type),value=$($_.condition_value)"})-join';'
    }else{''}
    $abilityRows=@($abilitiesByNo[[string]$ca.ability_no])
    $detailRows=@($detailsByNo[[string]$ca.ability_no])
    foreach($d in ($detailRows|Sort-Object {[int]$_.ability_awake_level}, {[int]$_.level})){
        $matching=@($abilityRows|Where-Object {[int]$_.ability_awake_level -eq [int]$d.ability_awake_level})
        if($matching.Count -eq 0){
            # Some low-rarity skills ship descriptions for later awake stages but
            # keep using their awake-0 runtime effect rows.
            $matching=@($abilityRows|Where-Object {[int]$_.ability_awake_level -eq 0})
        }
        if($matching.Count -eq 0){$matching=@($null)}
        foreach($a in $matching){
            $effect=if($a){$effects[[string]$a.m_ability_effects_id]}else{$null}
            $effectType=if($effect){$effectTypes[[string]$effect.type]}else{$null}
            # Each m_abilities row selects a runtime AbilityEffectAsset through
            # m_ability_effects_id. One displayed passive can contain several rows.
            $asset=if($a){$assetSummary[[string]$a.m_ability_effects_id]}else{$null}
            $long.Add([pscustomobject]@{
                CharacterId=$ca.m_character_id;CharacterName=$ch.name;CharacterRarity=$ch.rarity
                SkillOrder=$ca.order;CharacterAbilityId=$ca.id;SkillAssetId=$ca.asset_id;SkillName=$ca.name;AbilityNo=$ca.ability_no
                AwakeLevel=$d.ability_awake_level;Level=$d.level;Description=$d.description;AwakeDescription=$d.awake_description
                EffectAssetId=if($a){$a.m_ability_effects_id}else{$null};EffectValue=$effect.value;EffectTypeId=$effect.type;EffectTypeName=$effectType.name;EffectTypeCode=$effectType.type;EffectGrade=$effectType.grade
                TargetCode=if($asset){$asset.TargetCode}elseif($effectType -and [string]$effect.type -ne '1'){'ServerSide'}else{''}
                SituationCode=if($asset){$asset.SituationCode}elseif($effectType -and [string]$effect.type -ne '1'){'MasterData'}else{''}
                ScopeCode=if($asset){$asset.ScopeCode}else{''}
                RuntimeEffectCode=if($asset){$asset.EffectCode}elseif($effectType -and [string]$effect.type -ne '1'){"Server:$($effectType.type)"}else{''}
                ReleaseConditions=$releaseText
            })
        }
    }
}
$long|Export-Csv -LiteralPath (Join-Path $OutputDirectory 'character-small-skills-long.csv') -NoTypeInformation -Encoding UTF8
$long|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputDirectory 'character-small-skills-long.json') -Encoding UTF8

$fcAssetMap=@{}
$fcCsv=Join-Path $PSScriptRoot 'fc-target-output\fc-and-action-skill-targets.csv'
if(Test-Path -LiteralPath $fcCsv){foreach($x in Import-Csv -LiteralPath $fcCsv){$fcAssetMap[[string]$x.SkillId]=$x}}
$fcJoined=[Collections.Generic.List[object]]::new()
foreach($skill in ($tables.m_character_action_skills|Where-Object {[int]$_.trigger_type -eq 30}|Sort-Object {[long]$_.m_character_id})){
    $ch=$characters[[string]$skill.m_character_id];$asset=$fcAssetMap[[string]$skill.id]
    $fcJoined.Add([pscustomobject]@{
        CharacterId=$skill.m_character_id;CharacterName=$ch.name;CharacterRarity=$ch.rarity
        FcSkillId=$skill.id;FcName=$skill.name;FcDescription=$skill.description;TriggerType=$skill.trigger_type;TriggerTypeName='Chain/ForceChain'
        TargetType=$asset.TargetType;TargetTypeName=$asset.TargetTypeName;UnitTargetType=$asset.UnitTargetType;UnitTargetTypeName=$asset.UnitTargetTypeName
        AttackRangeType=$asset.AttackRangeType;AttackRangeTypeName=$asset.AttackRangeTypeName;AttackArea=$asset.AttackArea;IsAerialHit=$asset.IsAerialHit
        ExecuteConditionCode='UNRECOVERED_SERIALIZE_REFERENCE'
    })
}
$fcJoined|Export-Csv -LiteralPath (Join-Path $OutputDirectory 'character-fc-targets.csv') -NoTypeInformation -Encoding UTF8
$fcJoined|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'character-fc-targets.json') -Encoding UTF8

$coverage=[pscustomobject]@{
    Characters=$tables.m_characters.Count
    CharacterAbilities=$tables.m_character_abilities.Count
    CharactersWithExactlyThreeAbilities=@($tables.m_character_abilities|Group-Object m_character_id|Where-Object Count -eq 3).Count
    AbilityDetails=$tables.m_ability_details.Count
    LevelRows1To10=@($long|Where-Object {[int]$_.Level -ge 1 -and [int]$_.Level -le 10}).Count
    JoinedRuntimeTargets=@($long|Where-Object {$_.TargetCode}).Count
    ForceChainSkills=$fcJoined.Count
    ForceChainTargetsJoined=@($fcJoined|Where-Object {$_.TargetTypeName}).Count
}
$coverage|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'small-skill-coverage.json') -Encoding UTF8
Write-Host ($coverage|ConvertTo-Json -Compress)
Write-Host "Output: $((Resolve-Path $OutputDirectory).Path)"
