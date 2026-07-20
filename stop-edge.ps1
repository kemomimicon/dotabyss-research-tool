param([int]$Port = 9222)
$ErrorActionPreference = 'Stop'
try {
    $version = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"
} catch {
    Write-Host "No research Edge instance is listening on port $Port."
    exit 0
}
$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync(
    [Uri]$version.webSocketDebuggerUrl,
    [Threading.CancellationToken]::None
).GetAwaiter().GetResult() | Out-Null
$message = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Browser.close","params":{}}')
$socket.SendAsync(
    [ArraySegment[byte]]::new($message),
    [Net.WebSockets.WebSocketMessageType]::Text,
    $true,
    [Threading.CancellationToken]::None
).GetAwaiter().GetResult() | Out-Null
$socket.Dispose()
Write-Host "Research Edge close request sent."
