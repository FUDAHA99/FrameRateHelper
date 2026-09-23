param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$testBase = Join-Path ([IO.Path]::GetTempPath()) ('DeltaForceBooster-Tests\updater-download-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testBase)

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
}

if (-not ('DfbRangeRetryServer' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class DfbRangeRetryServer : IDisposable {
  private readonly TcpListener listener;
  private readonly Thread thread;
  private readonly byte[] payload;
  private readonly int slowChunkBytes;
  private readonly int stallMilliseconds;
  private readonly int successfulRequest;
  private readonly int maximumRequests;
  private readonly int busyRequests;
  private readonly List<string> ranges = new List<string>();
  private volatile bool stopping;
  private int requestCount;

  public DfbRangeRetryServer(byte[] payload, int slowChunkBytes, int stallMilliseconds,
      int successfulRequest, int maximumRequests)
      : this(payload, slowChunkBytes, stallMilliseconds, successfulRequest, maximumRequests, 0) { }

  public DfbRangeRetryServer(byte[] payload, int slowChunkBytes, int stallMilliseconds,
      int successfulRequest, int maximumRequests, int busyRequests) {
    this.payload = payload;
    this.slowChunkBytes = slowChunkBytes;
    this.stallMilliseconds = stallMilliseconds;
    this.successfulRequest = successfulRequest;
    this.maximumRequests = maximumRequests;
    this.busyRequests = busyRequests;
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    thread = new Thread(Run);
    thread.IsBackground = true;
    thread.Start();
  }

  public int Port { get; private set; }
  public string Url { get { return "http://127.0.0.1:" + Port + "/setup.exe"; } }
  public int RequestCount { get { return Volatile.Read(ref requestCount); } }
  public Exception Error { get; private set; }
  public string[] Ranges { get { lock (ranges) { return ranges.ToArray(); } } }

  private static string ReadHeaders(NetworkStream stream, out string range) {
    range = "";
    var all = new StringBuilder();
    using (var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true)) {
      string line;
      while ((line = reader.ReadLine()) != null) {
        if (line.Length == 0) break;
        all.AppendLine(line);
        if (line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) {
          range = line.Substring(6).Trim();
        }
      }
    }
    return all.ToString();
  }

  private static long ParseStart(string range) {
    if (String.IsNullOrEmpty(range)) return 0;
    const string prefix = "bytes=";
    if (!range.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return -1;
    string value = range.Substring(prefix.Length);
    int dash = value.IndexOf('-');
    long result;
    return dash > 0 && Int64.TryParse(value.Substring(0, dash), out result) ? result : -1;
  }

  private void Run() {
    try {
      while (!stopping && RequestCount < maximumRequests) {
        using (TcpClient client = listener.AcceptTcpClient()) {
          client.ReceiveTimeout = 5000;
          client.SendTimeout = 5000;
          using (NetworkStream stream = client.GetStream()) {
            string range;
            ReadHeaders(stream, out range);
            lock (ranges) { ranges.Add(range); }
            int current = Interlocked.Increment(ref requestCount);
            if (current <= busyRequests) {
              byte[] busy = Encoding.ASCII.GetBytes(
                "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
              stream.Write(busy, 0, busy.Length);
              stream.Flush();
              continue;
            }
            long start = ParseStart(range);
            if (start < 0 || start >= payload.LongLength) {
              byte[] invalid = Encoding.ASCII.GetBytes("HTTP/1.1 416 Range Not Satisfiable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
              stream.Write(invalid, 0, invalid.Length);
              stream.Flush();
              continue;
            }

            long remaining = payload.LongLength - start;
            bool partial = start > 0;
            var header = new StringBuilder();
            header.Append(partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n");
            header.Append("Accept-Ranges: bytes\r\n");
            header.Append("Content-Length: ").Append(remaining).Append("\r\n");
            if (partial) {
              header.Append("Content-Range: bytes ").Append(start).Append('-')
                .Append(payload.LongLength - 1).Append('/').Append(payload.LongLength).Append("\r\n");
            }
            header.Append("Connection: close\r\n\r\n");
            byte[] headerBytes = Encoding.ASCII.GetBytes(header.ToString());
            stream.Write(headerBytes, 0, headerBytes.Length);

            bool succeeds = successfulRequest > 0 && current == successfulRequest;
            int count = succeeds ? checked((int)remaining) : (int)Math.Min((long)slowChunkBytes, remaining);
            stream.Write(payload, checked((int)start), count);
            stream.Flush();
            if (!succeeds) Thread.Sleep(stallMilliseconds);
          }
        }
      }
    } catch (Exception ex) {
      if (!stopping) Error = ex;
    }
  }

  public void Dispose() {
    stopping = true;
    try { listener.Stop(); } catch { }
    if (thread != null && thread.IsAlive) thread.Join(3000);
  }
}
'@
}

if (-not ('DfbRedirectHopServer' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// 重定向 fixture：从第 redirectFromRequest 次请求起一律 302 到 location；在那之前（或 location 为空时）
// 回 200 + payload。partialBytes > 0 时只发这么多字节再停顿 stallMilliseconds，逼出客户端读超时，
// 让产品带 Range 续传——续传那一跳才被 302，用来验证「每一次尝试的最终地址都复查」。
public sealed class DfbRedirectHopServer : IDisposable {
  private readonly TcpListener listener;
  private readonly Thread thread;
  private readonly byte[] payload;
  private readonly string location;
  private readonly int redirectFromRequest;
  private readonly int partialBytes;
  private readonly int stallMilliseconds;
  private readonly int maximumRequests;
  private volatile bool stopping;
  private int requestCount;

  public DfbRedirectHopServer(byte[] payload, string location, int redirectFromRequest,
      int partialBytes, int stallMilliseconds, int maximumRequests) {
    this.payload = payload == null ? new byte[0] : payload;
    this.location = location == null ? "" : location;
    this.redirectFromRequest = redirectFromRequest;
    this.partialBytes = partialBytes;
    this.stallMilliseconds = stallMilliseconds;
    this.maximumRequests = maximumRequests;
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    thread = new Thread(Run);
    thread.IsBackground = true;
    thread.Start();
  }

  public int Port { get; private set; }
  public string Url { get { return "http://127.0.0.1:" + Port + "/setup.exe"; } }
  public int RequestCount { get { return Volatile.Read(ref requestCount); } }
  public Exception Error { get; private set; }

  private static void ReadHeaders(NetworkStream stream) {
    using (var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true)) {
      string line;
      while ((line = reader.ReadLine()) != null) {
        if (line.Length == 0) break;
      }
    }
  }

  private void Run() {
    try {
      while (!stopping && RequestCount < maximumRequests) {
        using (TcpClient client = listener.AcceptTcpClient()) {
          client.ReceiveTimeout = 5000;
          client.SendTimeout = 5000;
          using (NetworkStream stream = client.GetStream()) {
            ReadHeaders(stream);
            int current = Interlocked.Increment(ref requestCount);
            try {
              if (location.Length > 0 && current >= redirectFromRequest) {
                byte[] moved = Encoding.ASCII.GetBytes("HTTP/1.1 302 Found\r\nLocation: " + location +
                  "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                stream.Write(moved, 0, moved.Length);
                stream.Flush();
                continue;
              }
              byte[] head = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: " +
                payload.Length.ToString() + "\r\nConnection: close\r\n\r\n");
              stream.Write(head, 0, head.Length);
              int count = partialBytes > 0 ? Math.Min(partialBytes, payload.Length) : payload.Length;
              stream.Write(payload, 0, count);
              stream.Flush();
              if (partialBytes > 0) Thread.Sleep(stallMilliseconds);
            } catch (IOException) {
              // 客户端被策略拒绝后立刻断开，写一半失败是预期，不算 fixture 故障
            } catch (SocketException) {
            }
          }
        }
      }
    } catch (Exception ex) {
      if (!stopping) Error = ex;
    }
  }

  public void Dispose() {
    stopping = true;
    try { listener.Stop(); } catch { }
    if (thread != null && thread.IsAlive) thread.Join(3000);
  }
}
'@
}

function Get-TestSha256([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
  finally { $sha.Dispose() }
}

function New-TestPayload([int]$Length) {
  $bytes = New-Object byte[] $Length
  for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 37 + 11) % 251) }
  $bytes
}

. (Join-Path $root 'scripts\updater.ps1')

# 下载逻辑的生产白名单保持不变；测试只把同进程 loopback fixture 放行。生产策略按 host 判定，
# fixture 全在 127.0.0.1 上，所以这里按 origin(host:port) 判：登记进 TestDeniedOrigins 的端口就代表
# 「不在白名单里的地址」。桩只看传进来的 URL，产品要让下载走完就必须真的把重定向后的最终地址交给它。
# 每次判定都记下当时已收的字节数：拒绝必须发生在从被拒地址取任何字节之前，而不是先下完再拒。
$script:TestDeniedOrigins = New-Object 'System.Collections.Generic.HashSet[string]'
$script:TestPolicyQueries = New-Object 'System.Collections.Generic.List[object]'
$script:TestPolicyState = $null
function Test-BoosterSetupUrl([string]$Url) {
  $uri = $null
  $origin = ''
  $allowed = $false
  if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
    $origin = "$($uri.Host):$($uri.Port)"
    $allowed = ($uri.Host -eq '127.0.0.1') -and -not $script:TestDeniedOrigins.Contains($origin)
  }
  $receivedNow = $(if ($script:TestPolicyState) { [long]$script:TestPolicyState.Received } else { -1L })
  $script:TestPolicyQueries.Add([pscustomobject]@{ Origin = $origin; Received = $receivedNow })
  [pscustomobject]@{ Allowed = $allowed; Reason = $(if ($allowed) { '' } else { "test policy denied origin $origin" }) }
}
function Get-TestPolicyQueries([string]$Origin) {
  @($script:TestPolicyQueries | Where-Object { $_.Origin -eq $Origin })
}

$script:TestUpdaterStageRoot = $testBase
$script:TestUpdaterStageCounter = 0
function New-BoosterSecureStaging {
  param([switch]$ForceProgramData, [string]$Id, [Security.Principal.SecurityIdentifier]$ReaderSid)
  $script:TestUpdaterStageCounter++
  $dir = Join-Path $script:TestUpdaterStageRoot ("stage-$script:TestUpdaterStageCounter")
  [void][IO.Directory]::CreateDirectory($dir)
  [pscustomobject]@{ Directory = $dir; Elevated = $true }
}
function Protect-BoosterStaging {
  param([string]$Directory, [string[]]$Files, [bool]$Elevated, [Security.Principal.SecurityIdentifier]$ReaderSid)
}

try {
  # 下载入口临时返回 429 时自动遵从 Retry-After 重试，不向用户暴露 GetResponse 内部异常。
  $busyPayload = New-TestPayload 98317
  $busySha = Get-TestSha256 $busyPayload
  $busyServer = [DfbRangeRetryServer]::new($busyPayload, 8192, 0, 2, 2, 1)
  try {
    $busyState = @{ Received = 0L; Total = [long]$busyPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    Invoke-BoosterSetupDownload -SetupUrl $busyServer.Url -Sha256 $busySha -Size $busyPayload.Length -State $busyState `
      -TimeoutMs 1000 -MaxAttempts 3 -RetryDelayMs 50
    Assert-True ($busyState.Phase -eq 'done' -and $busyState.Done) 'HTTP 429 did not recover to a completed download'
    Assert-True ([int]$busyState.RetryCount -eq 1 -and $busyServer.RequestCount -eq 2) 'HTTP 429 retry count is wrong'
    Assert-True ($busyState.Error -notmatch '(?i)GetResponse|Too Many Requests|429') 'HTTP 429 exposed a raw WebException'
    Assert-True ((Test-Path -LiteralPath $busyState.File -PathType Leaf) -and (Get-FileHash -LiteralPath $busyState.File).Hash -eq $busySha) `
      'HTTP 429 retry failed final byte/hash verification'
  } finally { $busyServer.Dispose() }

  $busyFailedServer = [DfbRangeRetryServer]::new($busyPayload, 8192, 0, 0, 2, 2)
  try {
    $busyFailedState = @{ Received = 0L; Total = [long]$busyPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    Invoke-BoosterSetupDownload -SetupUrl $busyFailedServer.Url -Sha256 $busySha -Size $busyPayload.Length -State $busyFailedState `
      -TimeoutMs 1000 -MaxAttempts 2 -RetryDelayMs 50
    Assert-True ($busyFailedState.Phase -eq 'failed' -and $busyFailedState.Done) 'persistent HTTP 429 did not enter failed state'
    Assert-True ($busyFailedState.Error -like '*下载服务器持续繁忙*已自动尝试 2 次*' -and
      $busyFailedState.Error -notmatch '(?i)GetResponse|Too Many Requests|使用.*参数调用') `
      'persistent HTTP 429 did not produce a user-friendly error'
  } finally { $busyFailedServer.Dispose() }

  # 第一次响应只发送一段后停顿，触发与用户现场相同的 Read 超时；第二次必须带 Range 续传。
  $payload = New-TestPayload 196731
  $sha = Get-TestSha256 $payload
  $server = [DfbRangeRetryServer]::new($payload, 24576, 350, 2, 2)
  try {
    $state = @{ Received = 0L; Total = [long]$payload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    Invoke-BoosterSetupDownload -SetupUrl $server.Url -Sha256 $sha -Size $payload.Length -State $state `
      -TimeoutMs 100 -MaxAttempts 3 -RetryDelayMs 400
    Assert-True ($state.Phase -eq 'done' -and $state.Done) 'read timeout did not recover to a completed download'
    Assert-True ([long]$state.Received -eq $payload.Length -and [int]$state.RetryCount -eq 1) 'resumed progress or retry count is wrong'
    Assert-True ((Test-Path -LiteralPath $state.File -PathType Leaf) -and (Get-FileHash -LiteralPath $state.File).Hash -eq $sha) `
      'resumed file failed the final byte/hash verification'
    Assert-True ($server.RequestCount -eq 2 -and $server.Ranges.Count -eq 2 -and
      $server.Ranges[0] -eq '' -and $server.Ranges[1] -eq 'bytes=24576-') 'retry did not request the exact remaining range'
    Assert-True ($null -eq $server.Error) "loopback resume server failed: $($server.Error)"
  } finally { $server.Dispose() }

  # 连续失败达到上限时，不再把“使用 3 个参数调用 Read”这类运行时内部错误直接展示给用户。
  $failedPayload = New-TestPayload 65539
  $failedSha = Get-TestSha256 $failedPayload
  $failedServer = [DfbRangeRetryServer]::new($failedPayload, 8192, 350, 0, 2)
  try {
    $failedState = @{ Received = 0L; Total = [long]$failedPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    Invoke-BoosterSetupDownload -SetupUrl $failedServer.Url -Sha256 $failedSha -Size $failedPayload.Length -State $failedState `
      -TimeoutMs 100 -MaxAttempts 2 -RetryDelayMs 400
    Assert-True ($failedState.Phase -eq 'failed' -and $failedState.Done) 'retry exhaustion did not enter failed state'
    Assert-True ($failedState.Error -like '*连续中断或超时*已自动尝试 2 次*' -and
      $failedState.Error -notmatch '(?i)Read|3\s*个参数|调用.*参数') 'retry exhaustion exposed the raw Read invocation exception'
    Assert-True ($failedServer.RequestCount -eq 2 -and $failedServer.Ranges[1] -eq 'bytes=8192-') `
      'retry exhaustion did not preserve progress between attempts'
  } finally { $failedServer.Dispose() }

  # ---------- 重定向后的最终地址必须再过一次白名单，而且在取任何字节之前 ----------
  # GitHub 的 release 下载会 302 到 CDN 子域；只查最初的 setupUrl 等于没查。
  # 负例：放行入口 origin、拒绝 CDN origin。下载必须失败、一个字节都不取、不交付任何文件。
  $redirPayload = New-TestPayload 8192
  $redirSha = Get-TestSha256 $redirPayload
  $deniedCdn = $null; $deniedEntry = $null
  try {
    $deniedCdn = [DfbRedirectHopServer]::new($redirPayload, $null, 0, 0, 0, 4)
    $deniedEntry = [DfbRedirectHopServer]::new($null, $deniedCdn.Url, 1, 0, 0, 4)
    $deniedOrigin = "127.0.0.1:$($deniedCdn.Port)"
    [void]$script:TestDeniedOrigins.Add($deniedOrigin)
    $script:TestPolicyQueries.Clear()
    $stageBefore = [int]$script:TestUpdaterStageCounter
    $deniedState = @{ Received = 0L; Total = [long]$redirPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    $script:TestPolicyState = $deniedState
    Invoke-BoosterSetupDownload -SetupUrl $deniedEntry.Url -Sha256 $redirSha -Size $redirPayload.Length -State $deniedState `
      -TimeoutMs 2000 -MaxAttempts 3 -RetryDelayMs 50
    $script:TestPolicyState = $null

    # 入口放行、CDN 真的被访问到：这条负例是「过闸被拒」，不是「连不上」。
    Assert-True ($deniedEntry.RequestCount -eq 1 -and $deniedCdn.RequestCount -eq 1) `
      "redirect fixture did not make exactly one hop (entry=$($deniedEntry.RequestCount) cdn=$($deniedCdn.RequestCount))"
    Assert-True ($deniedState.Phase -eq 'failed' -and $deniedState.Done) 'denied redirect target did not fail the download'
    # 被拒 origin 的端口是运行时随机分配的，只可能来自对最终地址的那次判定。
    Assert-True ($deniedState.Error -like "*test policy denied origin $deniedOrigin*") `
      "denied redirect target did not surface the final-URL verdict: $($deniedState.Error)"
    $deniedQueries = @(Get-TestPolicyQueries $deniedOrigin)
    Assert-True ($deniedQueries.Count -ge 1 -and @($deniedQueries | Where-Object { $_.Received -ne 0 }).Count -eq 0) `
      'the final-URL verdict was not taken before the first byte of the redirected response'
    Assert-True ([long]$deniedState.Received -eq 0) `
      "denied redirect target transferred $($deniedState.Received) byte(s) before aborting"
    Assert-True (-not "$($deniedState.File)") 'denied redirect target still handed back a setup file path'
    Assert-True ([int]$script:TestUpdaterStageCounter -eq $stageBefore + 1) 'denied redirect case never reached staging'
    $deniedStage = Join-Path $testBase ("stage-" + ($stageBefore + 1))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $deniedStage 'DeltaForceBooster-Setup.exe'))) `
      'denied redirect target left a staged setup executable behind'
    Assert-True ($null -eq $deniedEntry.Error -and $null -eq $deniedCdn.Error) `
      "redirect fixture failed: $($deniedEntry.Error) / $($deniedCdn.Error)"
  } finally {
    $script:TestPolicyState = $null
    $script:TestDeniedOrigins.Clear()
    if ($deniedEntry) { $deniedEntry.Dispose() }
    if ($deniedCdn) { $deniedCdn.Dispose() }
  }

  # 正例：同样 302 到另一个 origin，策略放行就必须照常下载成功并通过校验，且判定的确是对最终地址做的。
  # 没有这一条，把「凡是重定向一律拒绝」写死也能让上面的负例变绿。
  $allowedCdn = $null; $allowedEntry = $null
  try {
    $allowedCdn = [DfbRedirectHopServer]::new($redirPayload, $null, 0, 0, 0, 4)
    $allowedEntry = [DfbRedirectHopServer]::new($null, $allowedCdn.Url, 1, 0, 0, 4)
    $script:TestPolicyQueries.Clear()
    $allowedState = @{ Received = 0L; Total = [long]$redirPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    $script:TestPolicyState = $allowedState
    Invoke-BoosterSetupDownload -SetupUrl $allowedEntry.Url -Sha256 $redirSha -Size $redirPayload.Length -State $allowedState `
      -TimeoutMs 2000 -MaxAttempts 3 -RetryDelayMs 50
    $script:TestPolicyState = $null
    Assert-True ($allowedEntry.RequestCount -eq 1 -and $allowedCdn.RequestCount -eq 1) 'allowed redirect did not go through the CDN hop'
    Assert-True ($allowedState.Phase -eq 'done' -and $allowedState.Done -and -not "$($allowedState.Error)") `
      "allowed redirect did not complete: $($allowedState.Error)"
    Assert-True ((Test-Path -LiteralPath $allowedState.File -PathType Leaf) -and
      (Get-FileHash -LiteralPath $allowedState.File).Hash -eq $redirSha) 'allowed redirect failed the final byte/hash verification'
    Assert-True (@(Get-TestPolicyQueries "127.0.0.1:$($allowedCdn.Port)").Count -ge 1) `
      'allowed redirect completed without the final URL ever being checked'
    Assert-True ($null -eq $allowedEntry.Error -and $null -eq $allowedCdn.Error) `
      "allowed redirect fixture failed: $($allowedEntry.Error) / $($allowedCdn.Error)"
  } finally {
    $script:TestPolicyState = $null
    if ($allowedEntry) { $allowedEntry.Dispose() }
    if ($allowedCdn) { $allowedCdn.Dispose() }
  }

  # 续传那一跳才被 302：第一次请求从放行的入口拿到 8192 字节后停顿（读超时），带 Range 重试时
  # 入口改为 302 到被拒 CDN。只在首次尝试复查最终地址的实现会在这里把 CDN 的内容收进来。
  $resumePayload = New-TestPayload 65536
  $resumeSha = Get-TestSha256 $resumePayload
  $resumeCdn = $null; $resumeEntry = $null
  try {
    $resumeCdn = [DfbRedirectHopServer]::new($resumePayload, $null, 0, 0, 0, 4)
    $resumeEntry = [DfbRedirectHopServer]::new($resumePayload, $resumeCdn.Url, 2, 8192, 400, 4)
    $resumeOrigin = "127.0.0.1:$($resumeCdn.Port)"
    [void]$script:TestDeniedOrigins.Add($resumeOrigin)
    $script:TestPolicyQueries.Clear()
    $resumeState = @{ Received = 0L; Total = [long]$resumePayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    $script:TestPolicyState = $resumeState
    Invoke-BoosterSetupDownload -SetupUrl $resumeEntry.Url -Sha256 $resumeSha -Size $resumePayload.Length -State $resumeState `
      -TimeoutMs 100 -MaxAttempts 3 -RetryDelayMs 500
    $script:TestPolicyState = $null
    Assert-True ($resumeEntry.RequestCount -eq 2 -and $resumeCdn.RequestCount -eq 1 -and [int]$resumeState.RetryCount -eq 1) `
      "resume-then-redirect fixture did not take the resumed hop (entry=$($resumeEntry.RequestCount) cdn=$($resumeCdn.RequestCount) retry=$($resumeState.RetryCount))"
    Assert-True ($resumeState.Phase -eq 'failed' -and $resumeState.Error -like "*test policy denied origin $resumeOrigin*") `
      "redirect on a resumed attempt was not rejected: $($resumeState.Phase) $($resumeState.Error)"
    $resumeQueries = @(Get-TestPolicyQueries $resumeOrigin)
    Assert-True ($resumeQueries.Count -ge 1 -and @($resumeQueries | Where-Object { $_.Received -ne 8192 }).Count -eq 0 -and
      [long]$resumeState.Received -eq 8192) `
      "resumed attempt took bytes from the denied origin (received $($resumeState.Received), only 8192 came from the allowed entry)"
    Assert-True (-not "$($resumeState.File)") 'redirect on a resumed attempt still handed back a setup file path'
  } finally {
    $script:TestPolicyState = $null
    $script:TestDeniedOrigins.Clear()
    if ($resumeEntry) { $resumeEntry.Dispose() }
    if ($resumeCdn) { $resumeCdn.Dispose() }
  }

  $guiSource = [IO.File]::ReadAllText((Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'))
  Assert-True ($guiSource -match '\$st\.Status' -and $guiSource -match "Status = '正在下载更新…'; RetryCount = 0" -and
    $guiSource -match "Phase -eq 'downloading'") `
    'update dialog does not surface retry/resume status'

  'PASS updater download: Read timeout resumes with Range, exhaustion is user-friendly, denied redirect targets are rejected before any byte'
} finally {
  if ($KeepArtifacts) { "artifacts: $testBase" }
  elseif (Test-Path -LiteralPath $testBase) { Remove-Item -LiteralPath $testBase -Recurse -Force }
}
