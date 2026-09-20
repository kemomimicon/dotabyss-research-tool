param(
    [int]$Port = 9222,
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$target = (Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 5) |
    Where-Object { $_.type -eq 'iframe' -and $_.url -match 'api\.abyss-prod\.dotabyss\.dmmgames\.com/pc/iframe' } |
    Select-Object -First 1
if (-not $target) { throw 'DotAbyss Unity iframe not found.' }

$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
$buffer = New-Object byte[] 1048576
$nextId = 0
function Send-Cdp([string]$Method, $Params=@{}) {
    $script:nextId++
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{id=$script:nextId;method=$Method;params=$Params}|ConvertTo-Json -Depth 8 -Compress))
    $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    return $script:nextId
}
function Receive-Cdp {
    $stream = [IO.MemoryStream]::new()
    do {
        $result = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $stream.Write($buffer, 0, $result.Count)
    } until ($result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
}

try {
    Send-Cdp 'Network.enable' @{maxTotalBufferSize=268435456;maxResourceBufferSize=201326592} | Out-Null
    $quoted = $Url | ConvertTo-Json -Compress
    Send-Cdp 'Runtime.evaluate' @{expression="fetch($quoted,{cache:'no-store'}).then(r=>r.arrayBuffer()).then(b=>b.byteLength)";awaitPromise=$true;returnByValue=$true} | Out-Null
    $requestId=$null; $bodyCommandId=$null; $base64CommandId=$null; $status=$null
    while ($true) {
        $message = Receive-Cdp
        if ($message.method -eq 'Network.responseReceived' -and $message.params.response.url -eq $Url) {
            $requestId=[string]$message.params.requestId; $status=[int]$message.params.response.status
        } elseif ($requestId -and $message.method -eq 'Network.loadingFinished' -and [string]$message.params.requestId -eq $requestId) {
            if ($status -lt 200 -or $status -ge 300) { throw "HTTP $status while fetching $Url" }
            $bodyCommandId=Send-Cdp 'Network.getResponseBody' @{requestId=$requestId}
        } elseif ($bodyCommandId -and $message.id -eq $bodyCommandId) {
            if ($message.result.base64Encoded) {
                $bytes=[Convert]::FromBase64String([string]$message.result.body)
                break
            }
            $expression="fetch($quoted,{cache:'no-store'}).then(async r=>{if(!r.ok)throw new Error('HTTP '+r.status);const b=await r.arrayBuffer();const u=new Uint8Array(b);let s='';for(let i=0;i<u.length;i+=32768)s+=String.fromCharCode(...u.subarray(i,i+32768));return btoa(s)})"
            $base64CommandId=Send-Cdp 'Runtime.evaluate' @{expression=$expression;awaitPromise=$true;returnByValue=$true}
            $bodyCommandId=$null
        } elseif ($base64CommandId -and $message.id -eq $base64CommandId) {
            if ($message.result.exceptionDetails) { throw [string]$message.result.exceptionDetails.text }
            $encoded=[string]$message.result.result.value
            if (-not $encoded) { throw 'Browser base64 fetch returned no data.' }
            $bytes=[Convert]::FromBase64String($encoded)
            break
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $OutputFile -Parent) | Out-Null
    [IO.File]::WriteAllBytes($OutputFile, $bytes)
    Write-Host "Fetched $($bytes.Length) bytes: $([IO.Path]::GetFileName($OutputFile))"
} finally { $socket.Dispose() }
