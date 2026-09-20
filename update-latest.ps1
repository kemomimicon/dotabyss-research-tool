[CmdletBinding()]
param(
    [int]$Port = 9222,
    [switch]$SkipBrowserLaunch,
    [switch]$SkipImages,
    [switch]$SkipCharacterStands,
    [string]$CharacterStandDirectory = "",
    [string]$TavernStandDirectory = "",
    [switch]$CloseBrowserWhenDone
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
if (-not $CharacterStandDirectory) { $CharacterStandDirectory = Join-Path $root '.local-assets\character-stands-g' }
if (-not $TavernStandDirectory) { $TavernStandDirectory = Join-Path $root '.local-assets\tavern-character-stands' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $root ".local-update\$stamp"
$rawDirectory = Join-Path $runDirectory 'raw'
$generatedDirectory = Join-Path $runDirectory 'generated'
$smallOutput = Join-Path $generatedDirectory 'small-skill-output'
$timelineOutput = Join-Path $generatedDirectory 'character-timeline-output'
$imageBundleDirectory = Join-Path $rawDirectory 'image-bundles'
$imageOutput = Join-Path $generatedDirectory 'images'
$standBundleDirectory = Join-Path $rawDirectory 'character-stand-bundles'
$tavernStandBundleDirectory = Join-Path $rawDirectory 'tavern-character-stand-bundles'
New-Item -ItemType Directory -Force $rawDirectory,$smallOutput,$timelineOutput | Out-Null

function Test-DebugPort {
    try { $null=Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; return $true }
    catch { return $false }
}

function Get-GameTarget {
    $targets = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
    return $targets | Where-Object {
        $_.type -eq 'iframe' -and $_.url -match 'api\.abyss-prod\.dotabyss\.dmmgames\.com/pc/iframe'
    } | Select-Object -First 1
}

function Get-GameResourceEntries {
    $target = Get-GameTarget
    if (-not $target) { return @() }
    $socket=[Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    try {
        $expression = @'
JSON.stringify(performance.getEntriesByType('resource').map(x=>x.name).filter(x=>/\/aas\/\d+\/aa\/(catalog_1\.bin|general-common_assets_all_[^/?]+\.bundle)(?:\?|$)/i.test(x)))
'@
        $command=@{id=1;method='Runtime.evaluate';params=@{expression=$expression;returnByValue=$true}}|ConvertTo-Json -Depth 8 -Compress
        $bytes=[Text.Encoding]::UTF8.GetBytes($command)
        $socket.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        $buffer=New-Object byte[] 1048576
        while($true){
            $stream=[IO.MemoryStream]::new()
            do{
                $result=$socket.ReceiveAsync([ArraySegment[byte]]::new($buffer),[Threading.CancellationToken]::None).GetAwaiter().GetResult()
                $stream.Write($buffer,0,$result.Count)
            }until($result.EndOfMessage)
            $message=[Text.Encoding]::UTF8.GetString($stream.ToArray())|ConvertFrom-Json
            if($message.id -eq 1){
                if($message.result.exceptionDetails){throw [string]$message.result.exceptionDetails.text}
                return @(([string]$message.result.result.value | ConvertFrom-Json))
            }
        }
    } finally { $socket.Dispose() }
}

function Invoke-Python([string[]]$Arguments) {
    & $script:pythonPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Python command failed with exit code $LASTEXITCODE." }
}

function Fetch-Resource([string]$Url,[string]$Destination) {
    & (Join-Path $root 'fetch-browser-resource.ps1') -Port $Port -Url $Url -OutputFile $Destination
}

Write-Host '=== DotAbyss local data updater ===' -ForegroundColor Cyan
    if (-not (Test-DebugPort)) {
        if ($SkipBrowserLaunch) { throw "No Edge debugging endpoint is listening on port $Port." }
        & (Join-Path $root 'launch-edge.ps1') -Port $Port
    }
    Write-Host ''
    Write-Host 'Log in through the separate Edge window and wait at the game main screen.' -ForegroundColor Yellow
    $null = Read-Host 'Press Enter to start extraction'

    $entries=@()
    for($attempt=1;$attempt -le 3;$attempt++){
        $entries=@(Get-GameResourceEntries)
        $commonUrl=[string]($entries|Where-Object{$_ -match '/general-common_assets_all_[^/?]+\.bundle(?:\?|$)'}|Select-Object -Last 1)
        $catalogUrl=[string]($entries|Where-Object{$_ -match '/catalog_1\.bin(?:\?|$)'}|Select-Object -Last 1)
        if($commonUrl -and $catalogUrl){break}
        if($attempt -lt 3){
            Write-Warning 'Resource URLs are incomplete. Refresh the game main screen with Ctrl+R and wait for loading to finish.'
            $null=Read-Host 'Press Enter to retry'
        }
    }
    if(-not $commonUrl -or -not $catalogUrl){throw 'Could not detect public resource URLs. Confirm that the game main screen is fully loaded.'}
    if($commonUrl -notmatch '/aas/(\d+)/aa/'){throw 'Could not parse the resource version.'}
    $resourceVersion=$Matches[1]
    $baseUrl=$commonUrl.Substring(0,$commonUrl.LastIndexOf('/')+1)
    Write-Host "Detected resource version: $resourceVersion" -ForegroundColor Green

    $python=(Get-Command python.exe -ErrorAction SilentlyContinue)
    if(-not $python){$python=Get-Command python -ErrorAction SilentlyContinue}
    if(-not $python){throw 'Python 3 was not found in PATH.'}
    $script:pythonPath=$python.Source
    $localPython=Join-Path $root '.local-python'
    New-Item -ItemType Directory -Force $localPython|Out-Null
    $env:PYTHONPATH=if($env:PYTHONPATH){"$localPython;$env:PYTHONPATH"}else{$localPython}
    & $script:pythonPath -c 'import UnityPy' 2>$null
    if($LASTEXITCODE -ne 0){
        Write-Host 'Installing local UnityPy dependency...'
        Invoke-Python @('-m','pip','install','--disable-pip-version-check','--target',$localPython,'-r',(Join-Path $root 'requirements-unitypy.txt'))
    }

    $masterFile=Join-Path $rawDirectory 'download-cache.dat'
    $commonBundle=Join-Path $rawDirectory 'general-common.bundle'
    $catalogFile=Join-Path $rawDirectory 'catalog.bin'
    & (Join-Path $root 'export-master-cache.ps1') -Port $Port -OutputFile $masterFile
    Fetch-Resource $commonUrl $commonBundle
    Fetch-Resource $catalogUrl $catalogFile

    Invoke-Python @((Join-Path $root 'extract-ability-effects-unitypy.py'),$commonBundle,$smallOutput)
    & (Join-Path $root 'parse-small-skill-master.ps1') -MasterFile $masterFile -OutputDirectory $smallOutput

    $catalogText=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($catalogFile))
    $bundleNames=@([regex]::Matches($catalogText,'[A-Za-z0-9_./-]{1,500}\.bundle')|ForEach-Object{$_.Value}|Sort-Object -Unique)
    $timelineName=[regex]::Match($catalogText,'general-ingame-timelineextract_assets_assets_project_lazyassets_general_ingame_timelineextract_allcharactertimelineeffectvaluecatalog\.asset_[a-f0-9]+\.bundle','IgnoreCase').Value
    if(-not $timelineName){throw 'Timeline catalog bundle was not found in catalog.bin.'}
    $timelineBundle=Join-Path $rawDirectory $timelineName
    Fetch-Resource ($baseUrl+$timelineName) $timelineBundle
    Invoke-Python @(
        (Join-Path $root 'extract-character-timelines-unitypy.py'),
        $timelineBundle,
        $timelineOutput,
        '--preserve-unchanged-from',(Join-Path $root 'character-timeline-output')
    )

    $coverage=Get-Content (Join-Path $smallOutput 'small-skill-coverage.json') -Raw|ConvertFrom-Json
    $abilityReport=Get-Content (Join-Path $smallOutput 'ability-effect-extraction-report.json') -Raw|ConvertFrom-Json
    $timelineReport=Get-Content (Join-Path $timelineOutput 'extraction-report.json') -Raw|ConvertFrom-Json
    if([int]$coverage.JoinedRuntimeTargets -ne [int]$coverage.LevelRows1To10){throw 'Runtime target coverage is incomplete; generated data was not installed.'}
    if([int]$abilityReport.MissingReferences -ne 0 -or @($abilityReport.ReadErrors).Count -ne 0){throw 'Ability bundle contains unresolved objects; generated data was not installed.'}

    Copy-Item (Join-Path $smallOutput '*') (Join-Path $root 'small-skill-output') -Force
    Copy-Item (Join-Path $timelineOutput '*') (Join-Path $root 'character-timeline-output') -Force

    if(-not $SkipImages){
        $desiredIds=@(Import-Csv (Join-Path $smallOutput 'm_characters.csv')|ForEach-Object{'{0:D4}01000G' -f [int]$_.original_m_character_id}|Sort-Object -Unique)
        $knownIds=if(Test-Path (Join-Path $root 'character-gallery\image-map.csv')){@(Import-Csv (Join-Path $root 'character-gallery\image-map.csv')|Select-Object -ExpandProperty CharacterId -Unique)}else{@()}
        $missingIds=@($desiredIds|Where-Object{$_ -notin $knownIds})
        if($missingIds.Count){
            New-Item -ItemType Directory -Force $imageBundleDirectory,$imageOutput|Out-Null
            $imageNames=@($bundleNames|Where-Object{
                $name=$_.ToLowerInvariant()
                $matchesId=@($missingIds|Where-Object{$name.Contains($_.ToLowerInvariant())}).Count -gt 0
                $matchesKind=$name.StartsWith('normal-only-icon-characutin_') -or $name.StartsWith('normal-only-icon-charaicon-l_') -or $name.StartsWith('normal-only-icon-charaicon-m_') -or $name.StartsWith('normal-only-icon-charaicon_assets_')
                $matchesId -and $matchesKind -and ($name.Contains('_g_') -or $name.Contains('characutin') -or $name.Contains('charaicon_stat_g_'))
            })
            foreach($name in $imageNames){Fetch-Resource ($baseUrl+$name) (Join-Path $imageBundleDirectory $name)}
            Invoke-Python @((Join-Path $root 'extract-unity-textures.py'),$imageBundleDirectory,$imageOutput)
            Copy-Item (Join-Path $imageOutput '*.png') (Join-Path $root 'character-gallery\images') -Force
        }
        $catalogList=Join-Path $runDirectory 'character-catalog.txt'
        Get-ChildItem $timelineOutput -Filter 'CharacterTimelineEffectValueAsset_*.csv'|ForEach-Object{if($_.BaseName -match '_([0-9A-Za-z]+)$'){"    - $($Matches[1])"}}|Sort-Object -Unique|Set-Content $catalogList -Encoding utf8
        & (Join-Path $root 'build-character-gallery.ps1') -SourceDirectory (Join-Path $root 'character-gallery\images') -CharacterCatalogAsset $catalogList -OutputDirectory (Join-Path $root 'character-gallery') -NormalAttackCsv (Join-Path $root 'normal-attack-output\normal-attacks-summary.csv')
    }

    $standCount=0
    $tavernStandCount=0
    if(-not $SkipCharacterStands){
        $standPattern='^normal-only-charastand_.*_g_charastand([0-9]{9}g)\.prefab_[a-f0-9]+\.bundle$'
        $standResources=@($bundleNames|Where-Object{$_ -match $standPattern}|ForEach-Object{
            $null=$_ -match $standPattern
            [pscustomobject]@{CharacterId=$Matches[1].ToUpperInvariant();Name=$_}
        }|Sort-Object CharacterId -Unique)
        if(-not $standResources.Count){throw 'No all-ages character stand bundles were found in catalog.bin.'}
        New-Item -ItemType Directory -Force $standBundleDirectory,$CharacterStandDirectory|Out-Null
        $versionFile=Join-Path $CharacterStandDirectory '.resource-version'
        $savedVersion=if(Test-Path $versionFile){[string](Get-Content $versionFile -Raw).Trim()}else{''}
        $existingStandIds=@(Get-ChildItem $CharacterStandDirectory -File -Filter '*.png'|ForEach-Object{$_.BaseName})
        $standsAreCurrent=$savedVersion -eq $resourceVersion -and @($standResources|Where-Object{$_.CharacterId -notin $existingStandIds}).Count -eq 0
        if(-not $standsAreCurrent){
            foreach($resource in $standResources){
                Fetch-Resource ($baseUrl+$resource.Name) (Join-Path $standBundleDirectory ($resource.CharacterId+'.bundle'))
            }
            Invoke-Python @((Join-Path $root 'extract-character-stands.py'),$standBundleDirectory,$CharacterStandDirectory)
            Set-Content $versionFile $resourceVersion -Encoding ascii
        }
        $standCount=@(Get-ChildItem $CharacterStandDirectory -File -Filter '*.png').Count
        $skinFile=Join-Path $smallOutput 'm_character_skins.csv'
        if(Test-Path $skinFile){
            $tavernSkinRows=@(Import-Csv $skinFile|Where-Object{[int]$_.type -eq 2})
            $desiredTavernIds=@($tavernSkinRows|ForEach-Object{([string]$_.asset_id).ToUpperInvariant()}|Sort-Object -Unique)
            $tavernPattern='^normal-only-charastand_.*_x_charastand([0-9]{9}x)\.prefab_[a-f0-9]+\.bundle$'
            $tavernResources=@($bundleNames|Where-Object{$_ -match $tavernPattern}|ForEach-Object{
                $null=$_ -match $tavernPattern
                [pscustomobject]@{CharacterId=$Matches[1].ToUpperInvariant();Name=$_}
            }|Where-Object{$_.CharacterId -in $desiredTavernIds}|Sort-Object CharacterId -Unique)
            $missingTavernResources=@($desiredTavernIds|Where-Object{$_ -notin $tavernResources.CharacterId})
            if($missingTavernResources.Count){throw "Tavern stand bundles missing from catalog: $($missingTavernResources -join ', ')"}

            New-Item -ItemType Directory -Force $tavernStandBundleDirectory,$TavernStandDirectory|Out-Null
            $tavernVersionFile=Join-Path $TavernStandDirectory '.resource-version'
            $savedTavernVersion=if(Test-Path $tavernVersionFile){[string](Get-Content $tavernVersionFile -Raw).Trim()}else{''}
            $existingTavernIds=@(Get-ChildItem $TavernStandDirectory -File -Filter '*.png'|ForEach-Object{$_.BaseName})
            $tavernStandsAreCurrent=$savedTavernVersion -eq $resourceVersion -and @($desiredTavernIds|Where-Object{$_ -notin $existingTavernIds}).Count -eq 0
            if(-not $tavernStandsAreCurrent){
                foreach($resource in $tavernResources){
                    Fetch-Resource ($baseUrl+$resource.Name) (Join-Path $tavernStandBundleDirectory ($resource.CharacterId+'.bundle'))
                }
                Invoke-Python @((Join-Path $root 'extract-character-stands.py'),$tavernStandBundleDirectory,$TavernStandDirectory)
                Set-Content $tavernVersionFile $resourceVersion -Encoding ascii
            }

            $tavernRows=@($tavernSkinRows|ForEach-Object{
                $assetId=[string]$_.asset_id
                $source=Join-Path $TavernStandDirectory ($assetId+'.png')
                [pscustomobject]@{
                    CharacterSkinId=$_.id;CharacterId=$_.m_character_id;SkinType=$_.type;SkinTypeName='TavernWork'
                    Name=$_.name;AssetId=$assetId;IsDefault=$_.is_default;ImageAvailable=(Test-Path $source)
                }
            })
            $tavernRows|Export-Csv (Join-Path $TavernStandDirectory 'tavern-character-stands.csv') -NoTypeInformation -Encoding utf8
            $tavernStandCount=@($tavernRows|Where-Object{$_.ImageAvailable}).Count
        }
    }

    $summary=[ordered]@{
        ResourceVersion=$resourceVersion
        Characters=[int]$coverage.Characters
        CharacterAbilities=[int]$coverage.CharacterAbilities
        RuntimeRows=[int]$coverage.LevelRows1To10
        RuntimeTargetsJoined=[int]$coverage.JoinedRuntimeTargets
        ForceChainSkills=[int]$coverage.ForceChainSkills
        ForceChainTargetsJoined=[int]$coverage.ForceChainTargetsJoined
        AbilityEffectAssets=[int]$abilityReport.AbilityEffectAssets
        CharacterTimelineAssets=[int]$timelineReport.CharacterAssets
        TimelineEffectValues=[int]$timelineReport.RawEffectValues
        AllAgesCharacterStands=$standCount
        TavernCharacterStands=$tavernStandCount
        CharacterStandDirectory=if($SkipCharacterStands){$null}else{[IO.Path]::GetFullPath($CharacterStandDirectory)}
        TavernStandDirectory=if($SkipCharacterStands){$null}else{[IO.Path]::GetFullPath($TavernStandDirectory)}
        RunDirectory=$runDirectory
    }
    $summary|ConvertTo-Json|Set-Content (Join-Path $runDirectory 'result.json') -Encoding utf8
    Write-Host ''
    Write-Host 'Update completed successfully.' -ForegroundColor Green
    Write-Host ($summary|ConvertTo-Json -Compress)
Write-Host 'Review changes with: git status --short'
if($CloseBrowserWhenDone -and (Test-DebugPort)){
    try{& (Join-Path $root 'stop-edge.ps1') -Port $Port}catch{Write-Warning $_}
}
