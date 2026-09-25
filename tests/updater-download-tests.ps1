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

if (-not ('DfbFinalUriWebRequestCreator' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Threading;

// 最终 URI fixture：用 WebRequest.RegisterPrefix 接管一个唯一的 https://github.com/<guid>/ 前缀，
// 产品的 [Net.WebRequest]::Create 拿到的就是这里的请求；第 i 次 GetResponse 返回的响应 ResponseUri = FinalUris[i]
// （用完后一直用最后一个），相当于 AllowAutoRedirect 已经跟完 302。不联网、不解析 DNS。产品会给请求设的
// HttpWebRequest 专有成员（ReadWriteTimeout/UserAgent/AllowAutoRedirect/AddRange）在这里有同名成员，PowerShell 按运行时类型绑定。
// FirstBodyBytes >= 0：第一次响应的正文只给这么多字节就提前结束，逼产品带 Range 续传（AddRange 记下起点）。
// Proxy 非空：不给假请求，而是给一个经这个回环代理发出的真实 HttpWebRequest（目标 = FinalUris[0]，只用于 http 最终地址），
// 产品拿到的就是网络栈自己报告 ResponseUri 的真实 HttpWebResponse。
public sealed class DfbFinalUriWebRequestCreator : IWebRequestCreate {
  public Uri[] FinalUris = new Uri[0];
  public byte[] Payload = new byte[0];
  public int FirstBodyBytes = -1;
  public Uri Proxy;
  public int CreateCount;
  public int ResponseCount;
  public int StreamCount;
  public int RangeCount;
  public long LastRangeFrom = -1;

  public Uri FinalAt(int index) {
    if (FinalUris == null || FinalUris.Length == 0) throw new InvalidOperationException("final-URI fixture has no FinalUris");
    return FinalUris[Math.Min(index, FinalUris.Length - 1)];
  }

  public WebRequest Create(Uri uri) {
    Interlocked.Increment(ref CreateCount);
    if (Proxy != null) {
      HttpWebRequest real = (HttpWebRequest)WebRequest.CreateDefault(FinalAt(0));
      real.Proxy = new WebProxy(Proxy);
      return real;
    }
    return new DfbFinalUriWebRequest(this, uri);
  }
}

public sealed class DfbFinalUriWebRequest : WebRequest {
  private readonly DfbFinalUriWebRequestCreator owner;
  private readonly Uri requestUri;
  private int timeout = 100000;
  private long rangeFrom;
  public DfbFinalUriWebRequest(DfbFinalUriWebRequestCreator owner, Uri requestUri) {
    this.owner = owner;
    this.requestUri = requestUri;
  }
  public override Uri RequestUri { get { return requestUri; } }
  public override int Timeout { get { return timeout; } set { timeout = value; } }
  public int ReadWriteTimeout { get; set; }
  public string UserAgent { get; set; }
  public bool AllowAutoRedirect { get; set; }
  public void AddRange(long from) {
    rangeFrom = from;
    owner.LastRangeFrom = from;
    Interlocked.Increment(ref owner.RangeCount);
  }
  public override WebResponse GetResponse() {
    int index = Interlocked.Increment(ref owner.ResponseCount) - 1;
    return new DfbFinalUriWebResponse(owner, owner.FinalAt(index), index, rangeFrom);
  }
}

public sealed class DfbFinalUriWebResponse : WebResponse {
  private readonly DfbFinalUriWebRequestCreator owner;
  private readonly Uri finalUri;
  private readonly int index;
  private readonly long offset;
  public DfbFinalUriWebResponse(DfbFinalUriWebRequestCreator owner, Uri finalUri, int index, long offset) {
    this.owner = owner;
    this.finalUri = finalUri;
    this.index = index;
    this.offset = offset;
  }
  public override Uri ResponseUri { get { return finalUri; } }
  public override long ContentLength { get { return owner.Payload.LongLength - offset; } set { } }
  public override Stream GetResponseStream() {
    Interlocked.Increment(ref owner.StreamCount);
    int start = checked((int)offset);
    int count = owner.Payload.Length - start;
    if (index == 0 && owner.FirstBodyBytes >= 0) count = Math.Min(count, owner.FirstBodyBytes);
    return new MemoryStream(owner.Payload, start, count, false);
  }
  public override void Close() { }
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
# 下面会用回环桩覆盖 Test-BoosterSetupUrl；先把生产策略原样留一份，最后一组用例要把它接回真实下载函数。
$script:ProductionSetupUrlPolicy = ${function:Test-BoosterSetupUrl}

# 下载逻辑的生产白名单保持不变；测试只把同进程 loopback fixture 放行。生产策略按 host 判定，
# fixture 全在 127.0.0.1 上，所以这里按 origin(scheme://host:port) 判：登记进 TestDeniedOrigins 的就代表
# 「不在白名单里的地址」。scheme 必须一起比：只比 host:port 时，把最终地址 http 改写成 https 再判的实现
# 桩看不出来（复核 R5）。桩只看传进来的 URL，并原文记下，产品要让下载走完就必须真的把重定向后的最终地址交给它。
# 每次判定都记下当时已收的字节数：拒绝必须发生在从被拒地址取任何字节之前，而不是先下完再拒。
$script:TestDeniedOrigins = New-Object 'System.Collections.Generic.HashSet[string]'
$script:TestPolicyQueries = New-Object 'System.Collections.Generic.List[object]'
$script:TestPolicyState = $null
function Test-BoosterSetupUrl([string]$Url) {
  $uri = $null
  $origin = ''
  $allowed = $false
  if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
    $origin = "$($uri.Scheme)://$($uri.Host):$($uri.Port)"
    $allowed = ($uri.Host -eq '127.0.0.1') -and -not $script:TestDeniedOrigins.Contains($origin)
  }
  $receivedNow = $(if ($script:TestPolicyState) { [long]$script:TestPolicyState.Received } else { -1L })
  $script:TestPolicyQueries.Add([pscustomobject]@{ Url = $Url; Origin = $origin; Received = $receivedNow })
  [pscustomobject]@{ Allowed = $allowed; Reason = $(if ($allowed) { '' } else { "test policy denied origin $origin" }) }
}
function Get-TestPolicyQueries([string]$Origin) {
  @($script:TestPolicyQueries | Where-Object { $_.Origin -eq $Origin })
}
# 桩按调用顺序原文记下的 URL（调用方用 @() 包：单个元素时函数返回会被展开）。
function Get-TestPolicyUrls {
  @($script:TestPolicyQueries.ToArray() | ForEach-Object { "$($_.Url)" })
}
# 逐项 Ordinal 比较（-eq/-contains 不区分大小写，改写大小写的实现会混过去）。期望序列为空时一律不算相等，免得空对空。
function Test-OrdinalSequence([string[]]$Actual, [string[]]$Expected) {
  if ($null -eq $Actual -or $null -eq $Expected -or $Expected.Length -eq 0 -or $Actual.Length -ne $Expected.Length) { return $false }
  for ($i = 0; $i -lt $Expected.Length; $i++) {
    if (-not [string]::Equals($Actual[$i], $Expected[$i], [StringComparison]::Ordinal)) { return $false }
  }
  $true
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
    $deniedOrigin = "http://127.0.0.1:$($deniedCdn.Port)"
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
    # 策略收到的必须是 fixture 真实地址的原文（scheme 在内）：入口一次、CDN 最终地址一次，逐字相等（复核 R5）。
    $deniedQueryUrls = @(Get-TestPolicyUrls)
    Assert-True (Test-OrdinalSequence $deniedQueryUrls @($deniedEntry.Url, $deniedCdn.Url)) `
      "policy was not asked about the untouched entry and final URLs (denied redirect): [$($deniedQueryUrls -join '] [')] expected [$($deniedEntry.Url)] [$($deniedCdn.Url)]"
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
    Assert-True (@(Get-TestPolicyQueries "http://127.0.0.1:$($allowedCdn.Port)").Count -ge 1) `
      'allowed redirect completed without the final URL ever being checked'
    # 策略收到的必须是 fixture 真实地址的原文（scheme 在内）：入口一次、CDN 最终地址一次，逐字相等。
    $allowedQueryUrls = @(Get-TestPolicyUrls)
    Assert-True (Test-OrdinalSequence $allowedQueryUrls @($allowedEntry.Url, $allowedCdn.Url)) `
      "policy was not asked about the untouched entry and final URLs (allowed redirect): [$($allowedQueryUrls -join '] [')] expected [$($allowedEntry.Url)] [$($allowedCdn.Url)]"
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
    $resumeOrigin = "http://127.0.0.1:$($resumeCdn.Port)"
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
    # 每一次尝试都把那一次的最终地址原文交给策略：初始入口、第一次尝试（未重定向，仍是入口）、续传那次的 CDN。
    $resumeQueryUrls = @(Get-TestPolicyUrls)
    Assert-True (Test-OrdinalSequence $resumeQueryUrls @($resumeEntry.Url, $resumeEntry.Url, $resumeCdn.Url)) `
      "policy was not asked about the untouched URL of every attempt (resumed redirect): [$($resumeQueryUrls -join '] [')] expected [$($resumeEntry.Url)] [$($resumeEntry.Url)] [$($resumeCdn.Url)]"
  } finally {
    $script:TestPolicyState = $null
    $script:TestDeniedOrigins.Clear()
    if ($resumeEntry) { $resumeEntry.Dispose() }
    if ($resumeCdn) { $resumeCdn.Dispose() }
  }

  # ---------- 最终地址原样交给「生产」策略（复核 R5）----------
  # 上面的回环用例用的是桩策略；回环 fixture 只能是 http://127.0.0.1，生产策略一律拒绝，接不上。
  # 这里把生产 Test-BoosterSetupUrl 接回真实 Invoke-BoosterSetupDownload，用 DfbFinalUriWebRequestCreator 接管
  # 唯一的 https://github.com/<guid>/ 前缀：入口地址本身合法，响应的最终地址由用例指定。
  # 白名单域名上的 http 最终地址必须被拒、一个字节都不读；把实参先改写成 https 再判的实现会在这里放行并下载完成。
  # 生产策略外面只套一层记录：原样记下产品交来的 URL、再原样转交生产策略，用来逐字核对「交给策略的就是响应报告的最终地址」。
  $realPayload = New-TestPayload 12289
  $realSha = Get-TestSha256 $realPayload
  $realTag = 'dfb-final-uri-' + [guid]::NewGuid().ToString('N')
  $realEntryUrl = "https://github.com/$realTag/DeltaForceBooster-Setup.exe"
  $realHttpsCdn = "https://objects.githubusercontent.com/$realTag/DeltaForceBooster-Setup.exe"
  $realHttpCdn = "http://objects.githubusercontent.com/$realTag/DeltaForceBooster-Setup.exe"
  $realCreator = [DfbFinalUriWebRequestCreator]::new()
  $realCreator.Payload = $realPayload
  Assert-True ([Net.WebRequest]::RegisterPrefix("https://github.com/$realTag/", $realCreator)) `
    'could not register the final-URI WebRequest prefix'
  # 前提锚点：留下来的确实是 scripts\updater.ps1 里定义的那个函数，不是后面的回环桩。
  Assert-True ($null -ne $script:ProductionSetupUrlPolicy -and
    [string]::Equals("$($script:ProductionSetupUrlPolicy.File)", (Join-Path $root 'scripts\updater.ps1'), [StringComparison]::OrdinalIgnoreCase)) `
    "captured Test-BoosterSetupUrl is not the production one from scripts/updater.ps1: [$($script:ProductionSetupUrlPolicy.File)]"
  $script:RealPolicyUrls = New-Object 'System.Collections.Generic.List[string]'
  # 前提锚点：生产策略自己放行入口，对最终地址的判定就是预期值，拒绝时有原因。桩会拒掉所有非 127.0.0.1 地址，接错了过不了这里。
  function Get-RealVerdict([string]$FinalUrl, [bool]$ShouldAllow) {
    $entryVerdict = & $script:ProductionSetupUrlPolicy $realEntryUrl
    $finalVerdict = & $script:ProductionSetupUrlPolicy $FinalUrl
    Assert-True ([bool]$entryVerdict.Allowed -and [bool]$finalVerdict.Allowed -eq $ShouldAllow -and
      ($ShouldAllow -or [bool]"$($finalVerdict.Reason)")) `
      "production policy precondition broken for $FinalUrl (allowed=$($finalVerdict.Allowed))"
    $finalVerdict
  }
  function Invoke-RealFinalUriDownload([string[]]$FinalUrls, [int]$FirstBodyBytes = -1, [string]$ProxyUrl = '') {
    $realCreator.FinalUris = [uri[]]@($FinalUrls | ForEach-Object { [uri]$_ })
    $realCreator.FirstBodyBytes = $FirstBodyBytes
    $realCreator.Proxy = $(if ($ProxyUrl) { [uri]$ProxyUrl } else { $null })
    $realCreator.CreateCount = 0; $realCreator.ResponseCount = 0; $realCreator.StreamCount = 0
    $realCreator.RangeCount = 0; $realCreator.LastRangeFrom = -1
    $script:RealPolicyUrls.Clear()
    $state = @{ Received = 0L; Total = [long]$realPayload.Length; Phase = ''; Error = ''; File = ''; Cancel = $false; Done = $false }
    # 结果只看 $state；产品若往管道里吐东西也不能让返回值变成数组。
    $null = Invoke-BoosterSetupDownload -SetupUrl $realEntryUrl -Sha256 $realSha -Size $realPayload.Length -State $state `
      -TimeoutMs 2000 -MaxAttempts 3 -RetryDelayMs 50
    $state
  }
  function Assert-RealPolicyUrls([string[]]$Expected, [string]$What) {
    $got = @($script:RealPolicyUrls.ToArray())
    Assert-True (Test-OrdinalSequence $got $Expected) `
      "production policy was not handed the untouched URLs ($What): got [$($got -join '] [')] expected [$($Expected -join '] [')]"
  }
  function Test-RealStagedSetup([int]$Stage) {
    Test-Path -LiteralPath (Join-Path (Join-Path $testBase "stage-$Stage") 'DeltaForceBooster-Setup.exe')
  }

  $stubSetupUrlPolicy = ${function:Test-BoosterSetupUrl}
  ${function:Test-BoosterSetupUrl} = {
    param([string]$Url)
    $script:RealPolicyUrls.Add($Url)
    & $script:ProductionSetupUrlPolicy $Url
  }
  $realProxy = $null
  try {
    $realCases = @(
      @{ Final = $realHttpsCdn; Allowed = $true },
      @{ Final = $realHttpCdn; Allowed = $false },
      @{ Final = "http://github.com/$realTag/DeltaForceBooster-Setup.exe"; Allowed = $false },
      @{ Final = "https://objects.githubusercontent.com.evil.example/$realTag/DeltaForceBooster-Setup.exe"; Allowed = $false }
    )
    foreach ($case in $realCases) {
      $expected = Get-RealVerdict $case.Final $case.Allowed
      $stageBefore = [int]$script:TestUpdaterStageCounter
      $realState = Invoke-RealFinalUriDownload @($case.Final)
      Assert-True ($realCreator.CreateCount -eq 1 -and $realCreator.ResponseCount -eq 1 -and
        [int]$script:TestUpdaterStageCounter -eq $stageBefore + 1) `
        "final-URI fixture was not reached exactly once for $($case.Final) (create=$($realCreator.CreateCount) response=$($realCreator.ResponseCount) error=$($realState.Error))"
      if ($case.Allowed) {
        Assert-True ($realState.Phase -eq 'done' -and $realState.Done -and -not "$($realState.Error)" -and $realCreator.StreamCount -eq 1) `
          "allowlisted https final URL was not downloaded through the real policy: $($realState.Phase) $($realState.Error)"
        Assert-True ((Test-Path -LiteralPath $realState.File -PathType Leaf) -and
          (Get-FileHash -LiteralPath $realState.File).Hash -eq $realSha) 'allowlisted https final URL failed the final byte/hash verification'
      } else {
        Assert-True ($realState.Phase -eq 'failed' -and $realState.Done) `
          "real policy did not reject final URL $($case.Final) (phase=$($realState.Phase) received=$($realState.Received))"
        # 错误里必须正是生产策略对「未改写的」最终地址给出的原因；改写过的地址得出的原因不同（原因里带着地址），或者根本不拒。
        Assert-True ("$($realState.Error)".Contains("$($expected.Reason)")) `
          "download error is not the real verdict on the untouched final URL $($case.Final): $($realState.Error)"
        Assert-True ($realCreator.StreamCount -eq 0 -and [long]$realState.Received -eq 0 -and -not "$($realState.File)") `
          "rejected final URL $($case.Final) still had its body read (stream=$($realCreator.StreamCount) received=$($realState.Received))"
        Assert-True (-not (Test-RealStagedSetup ($stageBefore + 1))) `
          "rejected final URL $($case.Final) left a staged setup executable behind"
      }
      # 复核 R5 的核心：交给策略的值就是响应报告的最终地址原文（入口一次、最终地址一次），不是改写后的。
      Assert-RealPolicyUrls @($realEntryUrl, $case.Final) $case.Final
    }

    # 同一个 http 最终地址，这次是真实的 HttpWebRequest/HttpWebResponse：请求经回环代理发出，ResponseUri 由网络栈自己报告。
    # 只针对 System.Net.HttpWebResponse 的改写（例如 Update-TypeData 覆盖它的 ResponseUri）在上面的假响应上看不出来，这里接得住。
    # 代理对任何请求都回 200 + 正文；最终地址被拒，正文就一个字节都不能进文件。
    $realProxy = [DfbRedirectHopServer]::new($realPayload, $null, 0, 0, 0, 4)
    $expected = Get-RealVerdict $realHttpCdn $false
    $stageBefore = [int]$script:TestUpdaterStageCounter
    $realState = Invoke-RealFinalUriDownload @($realHttpCdn) -ProxyUrl "http://127.0.0.1:$($realProxy.Port)/"
    Assert-True ($realCreator.CreateCount -eq 1 -and $realCreator.ResponseCount -eq 0 -and $realProxy.RequestCount -eq 1 -and
      [int]$script:TestUpdaterStageCounter -eq $stageBefore + 1) `
      "real HttpWebRequest did not reach the loopback proxy exactly once (create=$($realCreator.CreateCount) proxy=$($realProxy.RequestCount) error=$($realState.Error))"
    Assert-True ($realState.Phase -eq 'failed' -and $realState.Done) `
      "real policy did not reject the HttpWebResponse final URL $realHttpCdn (phase=$($realState.Phase) received=$($realState.Received))"
    Assert-True ("$($realState.Error)".Contains("$($expected.Reason)")) `
      "download error is not the real verdict on the untouched HttpWebResponse final URL: $($realState.Error)"
    Assert-True ([long]$realState.Received -eq 0 -and -not "$($realState.File)" -and -not (Test-RealStagedSetup ($stageBefore + 1))) `
      "rejected HttpWebResponse final URL still transferred $($realState.Received) byte(s) or left a setup file"
    Assert-RealPolicyUrls @($realEntryUrl, $realHttpCdn) 'real HttpWebResponse via loopback proxy'
    Assert-True ($null -eq $realProxy.Error) "loopback proxy fixture failed: $($realProxy.Error)"

    # 续传那一次才拿到 http 最终地址：第一次尝试的最终地址是放行的 https，正文给 4096 字节就提前结束，产品带 Range 续传；
    # 第二次响应的最终地址是同一白名单域名上的 http。只在首次尝试核对 scheme（或只在续传时改写实参）的实现，
    # 会把剩下的字节从明文地址收进来。
    [void](Get-RealVerdict $realHttpsCdn $true)
    $expected = Get-RealVerdict $realHttpCdn $false
    $stageBefore = [int]$script:TestUpdaterStageCounter
    $realState = Invoke-RealFinalUriDownload @($realHttpsCdn, $realHttpCdn) -FirstBodyBytes 4096
    Assert-True ($realCreator.CreateCount -eq 2 -and $realCreator.ResponseCount -eq 2 -and $realCreator.RangeCount -eq 1 -and
      $realCreator.LastRangeFrom -eq 4096 -and [int]$realState.RetryCount -eq 1 -and [int]$script:TestUpdaterStageCounter -eq $stageBefore + 1) `
      "final-URI fixture did not take exactly one resumed attempt (create=$($realCreator.CreateCount) response=$($realCreator.ResponseCount) range=$($realCreator.RangeCount)@$($realCreator.LastRangeFrom) retry=$($realState.RetryCount) error=$($realState.Error))"
    Assert-True ($realState.Phase -eq 'failed' -and $realState.Done) `
      "real policy did not reject the http final URL on a resumed attempt (phase=$($realState.Phase) received=$($realState.Received))"
    Assert-True ("$($realState.Error)".Contains("$($expected.Reason)")) `
      "download error is not the real verdict on the resumed attempt's untouched final URL: $($realState.Error)"
    Assert-True ($realCreator.StreamCount -eq 1 -and [long]$realState.Received -eq 4096 -and -not "$($realState.File)" -and
      -not (Test-RealStagedSetup ($stageBefore + 1))) `
      "resumed attempt read bytes from the rejected http final URL (stream=$($realCreator.StreamCount) received=$($realState.Received), only 4096 came from the https attempt)"
    Assert-RealPolicyUrls @($realEntryUrl, $realHttpsCdn, $realHttpCdn) 'resumed attempt'
  } finally {
    ${function:Test-BoosterSetupUrl} = $stubSetupUrlPolicy
    if ($realProxy) { $realProxy.Dispose() }
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
