param(
    [int]$Port = 9222,
    [string]$ProfileDirectory = (Join-Path $PSScriptRoot ".edge-research-profile")
)

$ErrorActionPreference = "Stop"
$edgeCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge was not found." }

New-Item -ItemType Directory -Force -Path $ProfileDirectory | Out-Null
$arguments = @(
    "--remote-debugging-port=$Port",
    "--user-data-dir=$ProfileDirectory",
    "--no-first-run",
    "--no-default-browser-check",
    "https://play.games.dmm.com/game/dotabyss_692437"
)

Start-Process -FilePath $edge -ArgumentList $arguments
Write-Host "Edge research window started on debugging port $Port."
Write-Host "Log in, enter the game, then run capture.ps1 in another PowerShell window."
