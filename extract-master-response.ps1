param(
    [int]$Port = 9222,
    [string]$OutputFile = (Join-Path $PSScriptRoot "master-data-output\api-user.msgpack"),
    [string]$ResponsePattern = '/api/user(?:\?|$)',
    [int]$MinimumPlainBytes = 100000,
    [int]$TimeoutSeconds = 180,
    [switch]$ClearGameStorage,
    [string]$ResponseLogFile = '',
    [switch]$NoReload,
    [string]$AppKeyBase64 = $env:DOTABYSS_APP_KEY_BASE64
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Receive-CdpMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$WaitMilliseconds = 10000
    )
    $stream = [IO.MemoryStream]::new()
    $buffer = New-Object byte[] 65536
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $cts = [Threading.CancellationTokenSource]::new($WaitMilliseconds)
        try {
            $result = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
        } catch [OperationCanceledException] {
            return '__CDP_WAIT_TIMEOUT__'
        } finally {
            $cts.Dispose()
        }
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $stream.Write($buffer, 0, $result.Count)
    } until ($result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray())
}

function Unprotect-Laravel {
    param([string]$Payload, [byte[]]$Key)
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
        if (-not $json.iv -or -not $json.value) { return $null }
        $iv = [Convert]::FromBase64String([string]$json.iv)
        $ciphertext = [Convert]::FromBase64String([string]$json.value)
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Key = $Key
        $aes.IV = $iv
        $aes.Mode = 'CBC'
        $aes.Padding = 'PKCS7'
        return [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($ciphertext, 0, $ciphertext.Length))
    } catch { return $null }
}

function Unprotect-Body {
    param([byte[]]$Body, [byte[]]$SecretKey, [string]$Session)
    try {
        if ($Body.Length -lt 32 -or (($Body.Length - 16) % 16) -ne 0) { return $null }
        $hmac = [Security.Cryptography.HMACSHA256]::new($SecretKey)
        $key = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Session))
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $Body[0..15]
        $aes.Mode = 'CBC'
        $aes.Padding = 'PKCS7'
        $ciphertext = $Body[16..($Body.Length - 1)]
        return $aes.CreateDecryptor().TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
    } catch { return $null }
}

$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
$pageTarget = $targets | Where-Object {
    $_.type -eq 'iframe' -and $_.url -match '^https://api\.abyss-prod\.dotabyss\.dmmgames\.com/pc/iframe(?:\?|$)'
} | Select-Object -First 1
if (-not $pageTarget) {
    $pageTarget = $targets | Where-Object {
        $_.type -eq 'page' -and $_.url -match 'play\.games\.dmm\.com/game/dotabyss'
    } | Select-Object -First 1
}
if (-not $pageTarget) { throw 'The DotAbyss DMM page is not open yet.' }
$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$pageTarget.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
$nextId = 0
$pending = @{}
$responseMeta = @{}
$sessions = [Collections.Generic.List[string]]::new()
$responseLog = [Collections.Generic.List[object]]::new()
if ([string]::IsNullOrWhiteSpace($AppKeyBase64)) {
    throw 'App key is required. Pass -AppKeyBase64 or set DOTABYSS_APP_KEY_BASE64 locally; never commit it.'
}
try {
    $appKey = [Convert]::FromBase64String($AppKeyBase64)
} catch {
    throw 'App key must be valid Base64.'
}
$complete = $false

function Send-Cdp([string]$Method, $Params = @{}, $Context = $null, [string]$SessionId = '') {
    $script:nextId++
    $command = @{ id=$script:nextId; method=$Method; params=$Params }
    if ($SessionId) { $command.sessionId = $SessionId }
    $payload = $command | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    if ($Context) { $pending[$script:nextId] = $Context }
    return $script:nextId
}

function Wait-CdpResult([int]$Id) {
    while ($true) {
        $raw = Receive-CdpMessage $socket
        if ($null -eq $raw) { throw 'The Edge debugging connection closed.' }
        $message = $raw | ConvertFrom-Json
        if ($message.id -eq $Id) { return $message }
    }
}

try {
    $pageSession = ''
    Send-Cdp 'Network.enable' @{ maxTotalBufferSize=104857600; maxResourceBufferSize=67108864 } | Out-Null
    Send-Cdp 'Target.setAutoAttach' @{ autoAttach=$true; waitForDebuggerOnStart=$false; flatten=$true } | Out-Null
    if ($ClearGameStorage) {
        Send-Cdp 'Storage.clearDataForOrigin' @{
            origin='https://api.abyss-prod.dotabyss.dmmgames.com'
            storageTypes='cache_storage,indexeddb,local_storage,service_workers,websql'
        } | Out-Null
        Send-Cdp 'Network.clearBrowserCache' @{} | Out-Null
        Write-Host 'Cleared only the DotAbyss game origin cache to force a fresh master download.'
    }
    if (-not $NoReload) {
        Send-Cdp 'Page.reload' @{ ignoreCache=$false } $null $pageSession | Out-Null
    }
    Write-Host "Waiting for a response matching: $ResponsePattern"
    $started = Get-Date

    while (-not $complete -and ((Get-Date) - $started).TotalSeconds -lt $TimeoutSeconds) {
        $remainingMs = [Math]::Max(1, [int](($TimeoutSeconds - ((Get-Date) - $started).TotalSeconds) * 1000))
        $raw = Receive-CdpMessage $socket $remainingMs
        if ($raw -eq '__CDP_WAIT_TIMEOUT__') { break }
        if ($null -eq $raw) { break }
        $message = $raw | ConvertFrom-Json

        if ($message.method -eq 'Target.attachedToTarget') {
            $child = [string]$message.params.sessionId
            $targetType = [string]$message.params.targetInfo.type
            if ($targetType -in @('page','iframe')) {
                Send-Cdp 'Network.enable' @{ maxTotalBufferSize=104857600; maxResourceBufferSize=67108864 } $null $child | Out-Null
            }
        }
        elseif ($message.method -in @('Network.requestWillBeSent','Network.requestWillBeSentExtraInfo')) {
            $requestHeaders = if ($message.method -eq 'Network.requestWillBeSent') {
                $message.params.request.headers
            } else {
                $message.params.headers
            }
            $requestSession = [string]$requestHeaders.'x-olg-session'
            if ($requestSession) {
                if (-not $sessions.Contains($requestSession)) { $sessions.Add($requestSession) }
                $plainRequestSession = Unprotect-Laravel -Payload $requestSession -Key $appKey
                if ($plainRequestSession -and -not $sessions.Contains($plainRequestSession)) {
                    $sessions.Add($plainRequestSession)
                }
            }
        }
        elseif ($message.method -eq 'Network.responseReceived') {
            $r = $message.params.response
            if ($ResponseLogFile) {
                try {
                    $safeUri = [Uri]$r.url
                    $safeUrl = $safeUri.GetLeftPart([UriPartial]::Path)
                } catch { $safeUrl = ([string]$r.url -replace '\?.*$', '') }
                $responseLog.Add([pscustomobject]@{
                    status=[int]$r.status
                    mimeType=[string]$r.mimeType
                    type=[string]$message.params.type
                    url=$safeUrl
                })
            }
            $sessionHeader = [string]$r.headers.'x-olg-session'
            if ($sessionHeader) {
                if (-not $sessions.Contains($sessionHeader)) { $sessions.Add($sessionHeader) }
                $plainSession = Unprotect-Laravel -Payload $sessionHeader -Key $appKey
                if ($plainSession -and -not $sessions.Contains($plainSession)) { $sessions.Add($plainSession) }
            }
            if ($r.url -match $ResponsePattern) {
                $key = "{0}:{1}" -f ([string]$message.sessionId), $message.params.requestId
                $responseMeta[$key] = [pscustomobject]@{
                    requestId=$message.params.requestId
                    sessionId=[string]$message.sessionId
                    responseSession=$sessionHeader
                }
                Write-Host "Found matching response; reading its encrypted body."
            }
        }
        elseif ($message.method -eq 'Network.loadingFinished') {
            $key = "{0}:{1}" -f ([string]$message.sessionId), $message.params.requestId
            if ($responseMeta.ContainsKey($key)) {
                Send-Cdp 'Network.getResponseBody' @{ requestId=$message.params.requestId } ([pscustomobject]@{ key=$key }) ([string]$message.sessionId)
            }
        }
        elseif ($message.id -and $pending.ContainsKey([int]$message.id)) {
            $context = $pending[[int]$message.id]
            $pending.Remove([int]$message.id)
            if ($message.result.body -ne $null) {
                $body = if ($message.result.base64Encoded) {
                    [Convert]::FromBase64String([string]$message.result.body)
                } else {
                    [Text.Encoding]::UTF8.GetBytes([string]$message.result.body)
                }
                $candidates = [Collections.Generic.List[string]]::new()
                $meta = $responseMeta[$context.key]
                if ($meta.responseSession) {
                    $candidates.Add([string]$meta.responseSession)
                    $plain = Unprotect-Laravel -Payload ([string]$meta.responseSession) -Key $appKey
                    if ($plain) { $candidates.Add($plain) }
                }
                foreach ($candidate in $sessions) { if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) } }

                foreach ($candidate in $candidates) {
                    $plainBody = Unprotect-Body -Body $body -SecretKey $appKey -Session $candidate
                    if ($plainBody -and $plainBody.Length -ge $MinimumPlainBytes) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile -Parent) | Out-Null
                        [IO.File]::WriteAllBytes($OutputFile, $plainBody)
                        Write-Host "Decrypted MessagePack saved: $OutputFile ($($plainBody.Length) bytes)"
                        $complete = $true
                        break
                    }
                }
                if (-not $complete) {
                    Write-Host 'The matching response was not the master body; continuing to listen.'
                }
            }
        }
    }
    if (-not $complete) { throw "Timed out after $TimeoutSeconds seconds before a decryptable matching response arrived." }
}
finally {
    if ($ResponseLogFile) {
        New-Item -ItemType Directory -Force -Path (Split-Path $ResponseLogFile -Parent) | Out-Null
        @($responseLog | Sort-Object url -Unique) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResponseLogFile -Encoding UTF8
    }
    if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        try { $socket.CloseOutputAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch {}
    }
    $socket.Dispose()
}
