[CmdletBinding()]
param(
    [int]$Port = 9222,
    [switch]$SkipBrowserLaunch,
    [switch]$SkipImages,
    [switch]$CloseBrowserWhenDone
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $root ".local-update\$stamp"
$rawDirectory = Join-Path $runDirectory 'raw'
$generatedDirectory = Join-Path $runDirectory 'generated'
$smallOutput = Join-Path $generatedDirectory 'small-skill-output'
$timelineOutput = Join-Path $generatedDirectory 'character-timeline-output'
$imageBundleDirectory = Join-Path $rawDirectory 'image-bundles'
$imageOutput = Join-Path $generatedDirectory 'images'
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
            $bundleNames=@([regex]::Matches($catalogText,'[A-Za-z0-9_./-]{1,300}\.bundle')|ForEach-Object{$_.Value}|Sort-Object -Unique)
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
