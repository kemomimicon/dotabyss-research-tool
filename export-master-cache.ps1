param(
    [int]$Port = 9222,
    [Parameter(Mandatory=$true)][string]$OutputFile,
    [int]$ChunkBytes = 524288
)

$ErrorActionPreference = 'Stop'
$target = (Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 5) |
    Where-Object { $_.type -eq 'iframe' -and $_.url -match 'api\.abyss-prod\.dotabyss\.dmmgames\.com/pc/iframe' } |
    Select-Object -First 1
if (-not $target) { throw 'DotAbyss Unity iframe not found. Enter the game main screen first.' }

$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
$buffer = New-Object byte[] 2097152
$nextId = 0

function Invoke-CdpEval([string]$Expression, [bool]$AwaitPromise = $false) {
    $script:nextId++
    $command = @{ id=$script:nextId; method='Runtime.evaluate'; params=@{
        expression=$Expression; returnByValue=$true; awaitPromise=$AwaitPromise
    }} | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($command)
    $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    while ($true) {
        $stream = [IO.MemoryStream]::new()
        do {
            $result = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $stream.Write($buffer, 0, $result.Count)
        } until ($result.EndOfMessage)
        $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
        if ($message.id -eq $script:nextId) {
            if ($message.result.exceptionDetails) { throw [string]$message.result.exceptionDetails.text }
            return $message.result.result.value
        }
    }
}

$initialize = @'
(async()=>{
  const db=await new Promise((resolve,reject)=>{
    const request=indexedDB.open('/idbfs');
    request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
  });
  const store=db.transaction('FILE_DATA','readonly').objectStore('FILE_DATA');
  const keys=await new Promise((resolve,reject)=>{
    const request=store.getAllKeys();request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
  });
  const candidates=[];
  for(const rawKey of keys){
    const key=String(rawKey);
    if(!/\/DownloadCache\/[^/]+\.dat$/i.test(key))continue;
    const record=await new Promise((resolve,reject)=>{
      const request=store.get(rawKey);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    });
    const bytes=record.contents instanceof Uint8Array?record.contents:new Uint8Array(record.contents);
    candidates.push({key,record,bytes});
  }
  if(!candidates.length)throw new Error('DownloadCache dat file not found');
  candidates.sort((a,b)=>b.bytes.length-a.bytes.length);
  const selected=candidates[0];
  db.close();
  window.__dotabyssMasterBytes=selected.bytes;
  return JSON.stringify({length:selected.bytes.length,candidateCount:candidates.length});
})()
'@

try {
    $metadata = (Invoke-CdpEval $initialize $true) | ConvertFrom-Json
    if (-not $metadata.length) { throw 'The selected master-data cache was empty.' }
    New-Item -ItemType Directory -Force (Split-Path $OutputFile -Parent) | Out-Null
    $output = [IO.File]::Open($OutputFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        for ($offset=0; $offset -lt [long]$metadata.length; $offset += $ChunkBytes) {
            $count = [Math]::Min($ChunkBytes, [long]$metadata.length-$offset)
            $expression = @"
(()=>{const a=window.__dotabyssMasterBytes.subarray($offset,$($offset+$count));let s='';for(let i=0;i<a.length;i+=32768)s+=String.fromCharCode.apply(null,a.subarray(i,Math.min(i+32768,a.length)));return btoa(s)})()
"@
            $chunk = [Convert]::FromBase64String([string](Invoke-CdpEval $expression))
            $output.Write($chunk, 0, $chunk.Length)
            Write-Progress -Activity 'Exporting master data' -Status "$($offset+$chunk.Length) / $($metadata.length) bytes" -PercentComplete ((100*($offset+$chunk.Length))/$metadata.length)
        }
    } finally { $output.Dispose() }
    Write-Progress -Activity 'Exporting master data' -Completed
    Write-Host "Master data exported: $($metadata.length) bytes."
} finally {
    try { Invoke-CdpEval 'delete window.__dotabyssMasterBytes' | Out-Null } catch {}
    $socket.Dispose()
}
