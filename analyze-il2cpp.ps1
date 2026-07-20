param(
    [Parameter(Mandatory=$true)][string]$Cpp2IL,
    [Parameter(Mandatory=$true)][string]$Wasm,
    [Parameter(Mandatory=$true)][string]$Metadata,
    [Parameter(Mandatory=$true)][string]$FrameworkJs,
    [string]$UnityVersion = "6000.3.8f1",
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "analysis-output")
)

$ErrorActionPreference = "Stop"
& $Cpp2IL `
    --force-binary-path (Resolve-Path $Wasm) `
    --force-metadata-path (Resolve-Path $Metadata) `
    --force-unity-version $UnityVersion `
    --wasm-framework-file (Resolve-Path $FrameworkJs) `
    --output-as diffable-cs `
    --output-to $OutputDirectory `
    --low-memory-mode
if ($LASTEXITCODE -ne 0) { throw "Cpp2IL exited with code $LASTEXITCODE" }

$project = Join-Path $OutputDirectory "DiffableCs\Project\Project"
$patterns = "damage|mana|buff|debuff|battle|enemy|status|critical|skill|timeline|effect|attack|defen"
$index = Get-ChildItem -Recurse -File -Filter "*.cs" -LiteralPath $project |
    Where-Object { $_.FullName -match $patterns } |
    ForEach-Object { [pscustomobject]@{ Path=$_.FullName.Substring($project.Length + 1); Name=$_.BaseName } }
$index | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $OutputDirectory "combat-type-index.csv")
Write-Host "Indexed $($index.Count) combat-related types."
