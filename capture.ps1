param(
    [int]$Port = 9222,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "captures"),
    [string]$UrlPattern = "(?i)^https://api\.abyss-prod\.dotabyss\.dmmgames\.com(?:/|$)",
    [int]$MaximumBodyMiB = 64,
    [int]$DurationSeconds = 0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Sanitize-Value {
    param($Value, [string]$Key = "")
    $secretNames = "(?i)^(authorization|cookie|set-cookie|.*token.*|.*session.*|password|passwd|.*secret.*|viewer|owner|mid|st|rpctoken|x-api-key)$"
    if ($Key -match $secretNames) { return "[REDACTED]" }
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($k in $Value.Keys) { $clean[$k] = Sanitize-Value $Value[$k] ([string]$k) }
        return $clean
    }
    if ($Value -is [PSCustomObject]) {
        $clean = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $clean[$p.Name] = Sanitize-Value $p.Value $p.Name }
        return $clean
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value | ForEach-Object { Sanitize-Value $_ $Key })
    }
    return $Value
}

function Sanitize-Url([string]$Url) {
    try {
        $uri = [Uri]$Url
        if (-not $uri.Query) { return $Url }
        $builder = [UriBuilder]$uri
        $pairs = @()
        foreach ($part in $uri.Query.TrimStart('?').Split('&')) {
            if (-not $part) { continue }
            $kv = $part.Split('=', 2)
            $key = [Uri]::UnescapeDataString($kv[0])
            if ($key -match "(?i)^(.*token.*|.*session.*|authorization|cookie|password|secret|viewer|owner|mid|st|rpctoken|x-api-key)$") {
                $pairs += ([Uri]::EscapeDataString($key) + "=%5BREDACTED%5D")
            } else { $pairs += $part }
        }
        $builder.Query = $pairs -join '&'
        return $builder.Uri.AbsoluteUri
    } catch { return $Url }
}

function Safe-Name([string]$Text) {
    $name = $Text -replace "^https?://", "" -replace "[?#].*$", "" -replace "[^A-Za-z0-9._-]", "_"
    if ($name.Length -gt 140) { $name = $name.Substring($name.Length - 140) }
    if (-not $name) { $name = "response" }
    return $name
}

function Receive-CdpMessage {
    param([System.Net.WebSockets.ClientWebSocket]$Socket)
    $stream = [System.IO.MemoryStream]::new()
    $buffer = New-Object byte[] 65536
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $result = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $stream.Write($buffer, 0, $result.Count)
    } until ($result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray())
}

$endpoint = "http://127.0.0.1:$Port/json/list"
try { $targets = Invoke-RestMethod -Uri $endpoint -TimeoutSec 3 }
catch { throw "Cannot reach Edge debugging port $Port. Run launch-edge.ps1 first." }

$target = $targets | Where-Object { $_.type -eq "page" -and $_.url -match "dotabyss|play\.games\.dmm\.com" } | Select-Object -First 1
if (-not $target) { throw "No DotAbyss tab was found on port $Port." }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$captureRoot = Join-Path $OutputDirectory $stamp
$bodyRoot = Join-Path $captureRoot "bodies"
New-Item -ItemType Directory -Force -Path $bodyRoot | Out-Null

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
$nextId = 0
$pending = @{}
$responses = @{}
$manifest = [Collections.Generic.List[object]]::new()

function Send-Cdp([string]$Method, $Params = @{}, $Context = $null, [string]$SessionId = "") {
    $script:nextId++
    $id = $script:nextId
    $command = @{ id = $id; method = $Method; params = $Params }
    if ($SessionId) { $command.sessionId = $SessionId }
    $payload = $command | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($Context) { $pending[$id] = $Context }
    return $id
}

Send-Cdp "Network.enable" @{ maxTotalBufferSize = 104857600; maxResourceBufferSize = ($MaximumBodyMiB * 1MB) } | Out-Null
Send-Cdp "Target.setAutoAttach" @{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true } | Out-Null
Write-Host "Capturing DotAbyss traffic. Re-enter a screen or start a battle to generate requests."
if ($DurationSeconds -gt 0) { Write-Host "Capture will stop automatically after $DurationSeconds seconds." }
else { Write-Host "Press Ctrl+C to stop." }
Write-Host "Output: $captureRoot"
$startedAt = Get-Date

try {
    while ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        if ($DurationSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $DurationSeconds) { break }
        $raw = Receive-CdpMessage $socket
        if ($null -eq $raw) { break }
        $message = $raw | ConvertFrom-Json

        if ($message.method -eq "Target.attachedToTarget") {
            $childSession = [string]$message.params.sessionId
            Send-Cdp "Network.enable" @{ maxTotalBufferSize = 104857600; maxResourceBufferSize = ($MaximumBodyMiB * 1MB) } $null $childSession | Out-Null
        }
        elseif ($message.method -eq "Network.responseReceived") {
            $r = $message.params.response
            if ($r.url -match $UrlPattern) {
                $responseKey = "{0}:{1}" -f ([string]$message.sessionId), $message.params.requestId
                $responses[$responseKey] = [pscustomobject]@{
                    requestId = $message.params.requestId
                    sessionId = [string]$message.sessionId
                    url = Sanitize-Url $r.url
                    status = $r.status
                    mimeType = $r.mimeType
                    type = $message.params.type
                    headers = Sanitize-Value $r.headers
                    timestamp = (Get-Date).ToString("o")
                }
                Write-Host ("[{0}] {1}" -f $r.status, $r.url)
            }
        }
        elseif ($message.method -eq "Network.loadingFinished") {
            $requestId = $message.params.requestId
            $responseKey = "{0}:{1}" -f ([string]$message.sessionId), $requestId
            if ($responses.ContainsKey($responseKey) -and $message.params.encodedDataLength -le ($MaximumBodyMiB * 1MB)) {
                $context = [pscustomobject]@{ key=$responseKey; sessionId=[string]$message.sessionId }
                Send-Cdp "Network.getResponseBody" @{ requestId = $requestId } $context ([string]$message.sessionId) | Out-Null
            }
        }
        elseif ($message.id -and $pending.ContainsKey([int]$message.id)) {
            $context = $pending[[int]$message.id]
            $pending.Remove([int]$message.id)
            $meta = $responses[$context.key]
            if ($message.result.body -ne $null) {
                $extension = if ($meta.mimeType -match "json") { ".json" } elseif ($meta.mimeType -match "javascript") { ".js" } elseif ($meta.mimeType -match "wasm") { ".wasm" } else { ".bin" }
                $fileName = "{0}-{1}{2}" -f $manifest.Count.ToString("D5"), (Safe-Name $meta.url), $extension
                $path = Join-Path $bodyRoot $fileName
                if ($message.result.base64Encoded) { [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($message.result.body)) }
                else { [IO.File]::WriteAllText($path, [string]$message.result.body, [Text.UTF8Encoding]::new($false)) }
                $manifest.Add([pscustomobject]@{ url=$meta.url; status=$meta.status; mimeType=$meta.mimeType; type=$meta.type; file=("bodies/"+$fileName); headers=$meta.headers; timestamp=$meta.timestamp })
            }
        }
    }
}
finally {
    $manifestPath = Join-Path $captureRoot "manifest.json"
    Sanitize-Value @($manifest) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        try {
            $socket.CloseOutputAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "capture complete", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        } catch {
            Write-Warning "Capture data was saved, but the debugging socket did not complete its closing handshake."
        }
    }
    $socket.Dispose()
    Write-Host "Saved $($manifest.Count) response bodies and a sanitized manifest."
}
