#requires -Version 5.1
<#
.SYNOPSIS
    深圳大学校园网断网自动重连脚本（Windows 版）—— 宿舍区 + 教学区双区适配。
.DESCRIPTION
    由任务计划程序周期性调用：检测到外网不通时，自动模拟网页认证完成登录。
    账号密码只通过 DPAPI 加密保存在本机（cred.xml），脚本与日志中不含明文密码。
    本脚本与 macOS 版 autologin.sh 逻辑等价（同一套深澜 Srun / eportal 协议）。
.NOTES
    适用 Windows 10 / 11 自带的 Windows PowerShell 5.1（无需安装任何额外软件）。
    请用 install.ps1 安装；直接运行本文件可做一次性检测。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ============================== 可调参数（可用 config.ps1 覆盖） ==============================
$DormSSIDs       = @('SZU_CTC&CMCC')                                  # 宿舍区 WiFi
$TeachSSIDs      = @('SZU_WLAN', 'SZU-WLAN')                          # 教学区 WiFi
$WiredMode       = 1                                                  # 有线/无法识别时按宿舍区处理
$CheckUrl        = 'https://www.baidu.com'                            # 外网连通性探针
$DormPortalUrl   = 'http://172.30.255.42:801/eportal/portal/login'    # 宿舍区新版 eportal
$DormPortalHost  = 'http://172.30.255.42:801/'                        # 宿舍门户可达性探测
$SrunBase        = 'https://net.szu.edu.cn'                           # 教学区深澜门户（域名）
$SrunAuthIP      = '172.31.63.36'                                     # 教学区认证服务器 IP（主通道）
$SrunAcId        = '8'                                                # 教学区 ac_id 兜底值（登录前会动态获取）
$CredName        = 'szu-portal'                                       # 凭据标识（仅用于日志提示）
$LoginCooldown   = 100                                                # 登录失败冷却（秒）
$TeachNetPrefix  = '172.26.'                                          # 教学区 IP 段
$DormNetPrefix   = '172.24.'                                          # 宿舍区 IP 段
$DebugNet        = 1                                                  # 1=输出区域识别/网络诊断日志
$HttpTimeout     = 8                                                  # 单次 HTTP 超时（秒）

$LocalBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
$StateDir  = Join-Path $LocalBase 'SZUAutoLogin'
$LogFile   = Join-Path $StateDir 'szu-autologin.log'
$CredFile  = Join-Path $StateDir 'cred.xml'
$LastFile  = Join-Path $StateDir '.last_login'
$ZoneCache = Join-Path $StateDir '.zone_cache'

# 加载用户配置（与 macOS 版 config.sh 对应；config.ps1 不入库）
$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $configPath) { . $configPath }

# TLS：强制 TLS 1.2，并对 IP 直连 HTTPS 跳过证书校验（自签 / 证书域名不匹配）
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor
        [System.Net.SecurityProtocolType]::Tls
} catch {}
# 证书回调在 Add-Type 之后以 C# 委托方式设置（见下方）

# ============================== 深澜加密（内嵌 C#，等价于 macOS 版 openssl/XXTEA） ==============================
$srunCs = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Security.Cryptography;

public static class SrunCrypto
{
    static readonly string B64Map = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA=";
    static readonly string B64Std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

    // 信任所有证书的回调（用于 IP 直连 HTTPS 的主机名不匹配/自签）。
    // 以 C# 静态方法 + 委托方式绑定，避免在无 Runspace 的 IO 线程执行 ScriptBlock。
    public static bool TrustAll(
        object sender,
        System.Security.Cryptography.X509Certificates.X509Certificate certificate,
        System.Security.Cryptography.X509Certificates.X509Chain chain,
        System.Net.Security.SslPolicyErrors sslPolicyErrors)
    {
        return true;
    }

    public static string HmacMD5Hex(string msg, string key)
    {
        using (HMACMD5 h = new HMACMD5(Encoding.UTF8.GetBytes(key)))
            return BytesHex(h.ComputeHash(Encoding.UTF8.GetBytes(msg)));
    }

    public static string Sha1Hex(string msg)
    {
        using (SHA1 sha = SHA1.Create())
            return BytesHex(sha.ComputeHash(Encoding.UTF8.GetBytes(msg)));
    }

    static string BytesHex(byte[] b)
    {
        StringBuilder sb = new StringBuilder(b.Length * 2);
        for (int i = 0; i < b.Length; i++) sb.Append(b[i].ToString("x2"));
        return sb.ToString();
    }

    // 字符串 -> uint 数组（对应深澜 JS 的 s()）：每 4 个字符小端合并，addLen 时末尾附加字符长度
    static uint[] S(string a, bool addLen)
    {
        int n = a.Length;
        int blocks = (n + 3) / 4;
        uint[] v = new uint[blocks + (addLen ? 1 : 0)];
        for (int i = 0; i < blocks; i++)
        {
            uint val = 0;
            for (int j = 0; j < 4; j++)
            {
                int idx = i * 4 + j;
                uint code = idx < n ? (uint)a[idx] : 0u;
                val |= code << (8 * j);
            }
            v[i] = val;
        }
        if (addLen) v[blocks] = (uint)n;
        return v;
    }

    // uint 数组 -> 字节（小端展开）；withLen 时丢弃末尾长度块
    static byte[] L(uint[] a, bool withLen)
    {
        List<byte> bytes = new List<byte>(a.Length * 4);
        for (int i = 0; i < a.Length; i++)
        {
            if (withLen && i == a.Length - 1) break;
            uint val = a[i];
            bytes.Add((byte)(val & 0xff));
            bytes.Add((byte)((val >> 8) & 0xff));
            bytes.Add((byte)((val >> 16) & 0xff));
            bytes.Add((byte)((val >> 24) & 0xff));
        }
        return bytes.ToArray();
    }

    // XXTEA 加密 -> 深澜自定义字母表 base64
    public static string XxteaEncryptToB64(string str, string key)
    {
        if (str == "") return "";
        uint[] v = S(str, true);
        uint[] k0 = S(key, false);
        uint[] k = new uint[4];
        for (int i = 0; i < 4; i++) k[i] = i < k0.Length ? k0[i] : 0u;

        int n = v.Length - 1;
        uint z = v[n], y = v[0];
        uint c = 0x9E3779B9u;
        uint m;
        uint q = (uint)(6 + 52 / (n + 1));
        uint d = 0;
        unchecked
        {
            while (0 < q--)
            {
                d = d + c;
                uint e = d >> 2 & 3;
                int p;
                for (p = 0; p < n; p++)
                {
                    y = v[p + 1];
                    m = (z >> 5) ^ (y << 2);
                    m += ((y >> 3) ^ (z << 4)) ^ (d ^ y);
                    m += k[(p & 3) ^ e] ^ z;
                    z = v[p] = v[p] + m;
                }
                y = v[0];
                m = (z >> 5) ^ (y << 2);
                m += ((y >> 3) ^ (z << 4)) ^ (d ^ y);
                m += k[(n & 3) ^ e] ^ z;
                z = v[n] = v[n] + m;
            }
        }
        return CustomBase64(L(v, false));
    }

    // 标准 base64 后逐字符替换为深澜字母表
    static string CustomBase64(byte[] data)
    {
        string std = Convert.ToBase64String(data);
        StringBuilder sb = new StringBuilder(std.Length);
        for (int i = 0; i < std.Length; i++)
        {
            int idx = B64Std.IndexOf(std[i]);
            sb.Append(idx >= 0 ? B64Map[idx] : std[i]);
        }
        return sb.ToString();
    }
}
'@
Add-Type -TypeDefinition $srunCs -Language CSharp

# 绑定证书信任回调到 C# 静态方法（跨线程/跨 .NET Framework 与 .NET Core 均健壮）
$script:TrustAllDelegate = [System.Delegate]::CreateDelegate(
    [System.Net.Security.RemoteCertificateValidationCallback],
    [SrunCrypto].GetMethod('TrustAll'))
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:TrustAllDelegate

# ============================== 基础工具 ==============================
function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Test-InList {
    param([string]$Item, [string[]]$List)
    foreach ($t in $List) { if ($Item -eq $t) { return $true } }
    return $false
}

# 通用 HTTP：支持 query 编码、是否跟随重定向、返回状态码/body/Location
function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [System.Collections.IDictionary]$Query,
        [string]$Method = 'GET',
        [bool]$FollowRedirect = $true,
        [int]$TimeoutSec = $HttpTimeout,
        [string]$Body = $null
    )
    if ($null -ne $Query -and $Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) {
            '{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Query[$k])
        }
        $sep = if ($Url.Contains('?')) { '&' } else { '?' }
        $Url = $Url + $sep + ($pairs -join '&')
    }

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $FollowRedirect
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.KeepAlive = $false

    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream()
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
    } catch {
        $resp = $null
    }

    if ($null -eq $resp) {
        return [pscustomobject]@{ Ok = $false; StatusCode = 0; Body = ''; Location = '' }
    }

    $status = [int]$resp.StatusCode
    $location = $resp.Headers['Location']
    $text = ''
    try {
        $rs = $resp.GetResponseStream()
        $sr = New-Object System.IO.StreamReader($rs, [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
        $sr.Close()
    } catch {}
    try { $resp.Close() } catch {}

    return [pscustomobject]@{ Ok = $true; StatusCode = $status; Body = $text; Location = $location }
}

# ============================== 网络信息 ==============================
function Get-WifiSSID {
    # netsh 对 WiFi 最可靠；无 WiFi / 有线时返回空
    try {
        $out = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -eq 0) {
            $line = $out |
                Where-Object { $_ -match '^\s*SSID\s*:' -and $_ -notmatch 'BSSID' } |
                Select-Object -First 1
            if ($line) { return ($line -split ':', 2)[1].Trim() }
        }
    } catch {}
    return ''
}

function Get-Gateway {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        return [string]$r.NextHop
    } catch { return '' }
}

function Get-LocalIP {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($route) {
            $ip = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($ip) { return [string]$ip.IPAddress }
        }
    } catch {}
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -First 1
        return [string]$ip.IPAddress
    } catch { return '' }
}

# ============================== 在线 / 门户探测 ==============================
function Test-Online {
    $r = Invoke-Http -Url $CheckUrl -Method GET -FollowRedirect $true -TimeoutSec $HttpTimeout
    return [bool]$r.Ok
}

function Test-DormPortal {
    $r = Invoke-Http -Url $DormPortalHost -FollowRedirect $true -TimeoutSec 5
    return [bool]$r.Ok
}

function Get-TeachState {
    $r = Invoke-Http -Url "$SrunBase/cgi-bin/rad_user_info" -FollowRedirect $true -TimeoutSec 6
    if (-not $r.Ok) { return '' }
    return [string]$r.Body
}

# ============================== 区域识别 ==============================
function Save-ZoneCache {
    param([string]$Zone)
    $gw = Get-Gateway
    if (-not $gw -or -not $Zone) { return }
    try { "$Zone`n$gw" | Set-Content -Path $ZoneCache -Encoding UTF8 } catch {}
}

function Get-ZoneCache {
    $gw = Get-Gateway
    if (-not $gw) { return '' }
    if (Test-Path $ZoneCache) {
        $lines = Get-Content $ZoneCache
        if ($lines.Count -ge 2 -and $lines[1] -eq $gw -and ($lines[0] -eq 'dorm' -or $lines[0] -eq 'teach')) {
            return [string]$lines[0]
        }
    }
    return ''
}

function Get-Zone {
    # ① SSID
    $ssid = Get-WifiSSID
    if ($ssid) {
        if (Test-InList $ssid $DormSSIDs)  { Save-ZoneCache 'dorm';  return 'dorm' }
        if (Test-InList $ssid $TeachSSIDs) { Save-ZoneCache 'teach'; return 'teach' }
    }
    # ② IP 段
    $ip = Get-LocalIP
    if ($ip) {
        if ($DormNetPrefix  -and $ip.StartsWith($DormNetPrefix))  { Save-ZoneCache 'dorm';  return 'dorm' }
        if ($TeachNetPrefix -and $ip.StartsWith($TeachNetPrefix)) { Save-ZoneCache 'teach'; return 'teach' }
    }
    # ③ 网关未变 → 沿用上次区域
    $cached = Get-ZoneCache
    if ($cached) { return $cached }
    # ④ 探测认证服务器
    $state = Get-TeachState
    $teachOk = [bool]$state
    $dormOk = Test-DormPortal
    if ($dormOk -and -not $teachOk) { Save-ZoneCache 'dorm';  return 'dorm' }
    if (-not $dormOk -and $teachOk) { Save-ZoneCache 'teach'; return 'teach' }
    if ($dormOk) { return 'dorm' }
    if ($WiredMode -and (Get-Gateway)) { return 'dorm' }
    if ($DebugNet -and $ip) { Write-Log "DEBUG 区域探测未决 ip=[$ip]" }
    return 'none'
}

# ============================== 凭据（DPAPI） ==============================
function Read-Credentials {
    if (-not (Test-Path $CredFile)) { return $false }
    try {
        $obj = Import-Clixml -Path $CredFile
        $account = [string]$obj.Account
        $secure = $obj.Password
        if ($null -eq $secure) { return $false }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ([string]::IsNullOrEmpty($account) -or [string]::IsNullOrEmpty($password)) { return $false }
        $script:cid  = $account
        $script:pass = $password
        return $true
    } catch { return $false }
}

# ============================== 宿舍区登录（新版 eportal） ==============================
function Login-Dorm {
    $q = [ordered]@{
        callback       = 'dr1003'
        login_method   = '1'
        user_account   = ",0,$cid"
        user_password  = $pass
        wlan_user_ip   = ''
        wlan_user_ipv6 = ''
        wlan_user_mac  = '000000000000'
        wlan_ac_ip     = ''
        wlan_ac_name   = ''
        jsVersion      = '4.1.3'
        terminal_type  = '1'
        lang           = 'zh-cn'
        v              = '10353'
    }
    $r = Invoke-Http -Url $DormPortalUrl -Query $q -FollowRedirect $true -TimeoutSec 8
    if ($r.Ok -and ($r.Body -match '"result"\s*:\s*1' -or $r.Body -match '已经在线' -or $r.Body -match '认证成功')) {
        Write-Log '网页自动登录成功(宿舍区)'
        Save-ZoneCache 'dorm'
        return 0
    }
    $snippet = ''
    if ($r.Body) { $snippet = ($r.Body -replace "`n", ''); $snippet = $snippet.Substring(0, [Math]::Min(200, $snippet.Length)) }
    Write-Log "网页自动登录失败(宿舍区): $snippet"
    return 1
}

# ============================== 教学区登录（深澜 Srun） ==============================
function Get-TeachAcId {
    param([string]$Base)
    if (-not $Base) { $Base = $SrunBase }
    $r = Invoke-Http -Url "$Base/" -FollowRedirect $true -TimeoutSec 6
    if ($r.Ok -and $r.Body -match 'ac_id=(\d+)') { return $Matches[1] }
    $r2 = Invoke-Http -Url "$Base/index_8.html" -FollowRedirect $true -TimeoutSec 6
    if ($r2.Ok -and $r2.Body -match 'ac_id=(\d+)') { return $Matches[1] }
    return $SrunAcId
}

function Get-Challenge {
    $callback = Get-Date -Format 'yyyyMMdd_HHmmss'
    $origin = ''
    $body = ''

    # 入口 1：域名 HTTPS；入口 2：IP 直连 HTTPS
    foreach ($o in @($SrunBase, "https://$SrunAuthIP")) {
        $r = Invoke-Http -Url "$o/cgi-bin/get_challenge" `
            -Query @{ callback = $callback; username = $cid } -FollowRedirect $true -TimeoutSec 6
        if ($r.Ok -and $r.Body -match '"res"\s*:\s*"ok"') { $origin = $o; $body = $r.Body; break }
    }
    # 入口 3：网关 302 重定向探测（探测地址用 IP 字面量，不依赖 DNS）
    if (-not $origin) {
        $loc = ''
        foreach ($probe in @('http://1.1.1.1/', 'http://2.2.2.2/', 'http://www.msftconnecttest.com/connecttest.txt')) {
            $pr = Invoke-Http -Url $probe -FollowRedirect $false -TimeoutSec 6
            if ($pr.Location) { $loc = $pr.Location; break }
        }
        if ($loc -match '(?i)(https?://[^/]+)') {
            $portalNew = $Matches[1]
            $r = Invoke-Http -Url "$portalNew/cgi-bin/get_challenge" `
                -Query @{ callback = $callback; username = $cid } -FollowRedirect $true -TimeoutSec 6
            if ($r.Ok -and $r.Body -match '"res"\s*:\s*"ok"') {
                $origin = $portalNew; $body = $r.Body
                Write-Log "  [门户探测] 使用网关重定向入口: $portalNew"
            }
        }
    }
    # 入口 4：IP HTTP，跟随 301 跳转
    if (-not $origin) {
        $r = Invoke-Http -Url "http://$SrunAuthIP/cgi-bin/get_challenge" `
            -Query @{ callback = $callback; username = $cid } -FollowRedirect $true -TimeoutSec 6
        if ($r.Ok -and $r.Body -match '"res"\s*:\s*"ok"') { $origin = "https://$SrunAuthIP"; $body = $r.Body }
    }
    return [pscustomobject]@{ Origin = $origin; Body = $body; Callback = $callback }
}

function Login-Teach {
    # ① 已在线则跳过
    $state = Get-TeachState
    if ($state -and $state -ne 'not_online_error') {
        Write-Log '教学区检测显示已在线(可能仅外网检测误报),跳过登录'
        return 0
    }
    # ② 取 challenge（多入口回退）
    $ch = Get-Challenge
    $token = ''; $ipAddr = ''; $res = ''
    if ($ch.Body -match '"challenge"\s*:\s*"([^"]*)"') { $token = $Matches[1] }
    if ($ch.Body -match '"client_ip"\s*:\s*"([^"]*)"') { $ipAddr = $Matches[1] }
    if ($ch.Body -match '"res"\s*:\s*"([^"]*)"')       { $res = $Matches[1] }

    if ($res -ne 'ok' -or -not $token) {
        $raw = if ($ch.Body) { $ch.Body.Substring(0, [Math]::Min(200, $ch.Body.Length)) } else { '(空)' }
        Write-Log '网页自动登录失败(教学区): 无法获得 challenge(全部入口不可达,疑似网络未就绪)'
        Write-Log "  [challenge原始返回] $raw"
        try {
            $dns = (Resolve-DnsName net.szu.edu.cn -ErrorAction Stop |
                Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) -join ' '
            if ($dns) { Write-Log "  [DNS解析] $dns" }
        } catch {}
        return 2
    }

    # ③ 动态 ac_id + 加密
    $acId = Get-TeachAcId $ch.Origin
    $encPwd = [SrunCrypto]::HmacMD5Hex($pass, $token)
    $info = '{{"username":"{0}","password":"{1}","ip":"{2}","acid":"{3}","enc_ver":"srun_bx1"}}' -f
        $cid, $pass, $ipAddr, $acId
    $encInfo = '{SRBX1}' + [SrunCrypto]::XxteaEncryptToB64($info, $token)
    $chk = [SrunCrypto]::Sha1("$token$cid$token$encPwd$token$acId$token$ipAddr$token`200$token`1$token$encInfo")

    # ④ 提交登录
    $lq = [ordered]@{
        callback = $ch.Callback
        action   = 'login'
        username = $cid
        password = "{MD5}$encPwd"
        chksum   = $chk
        info     = $encInfo
        ac_id    = $acId
        ip       = $ipAddr
        n        = '200'
        type     = '1'
    }
    $r = Invoke-Http -Url "$($ch.Origin)/cgi-bin/srun_portal" -Query $lq -FollowRedirect $true -TimeoutSec 8

    $loginRes = ''
    if ($r.Ok -and $r.Body -match '"res"\s*:\s*"([^"]*)"') { $loginRes = $Matches[1] }
    if ($loginRes -eq 'ok') {
        Write-Log '网页自动登录成功(教学区)'
        Save-ZoneCache 'teach'
        return 0
    }

    $errmsg = switch -Regex ($loginRes) {
        'auth_error|password_error' { '账号或密码错误' }
        'login_error'              { '登录被拒绝(可能已在线或参数异常)' }
        '^$'                       { '无返回信息,可能认证系统已变更' }
        default                    { $loginRes }
    }
    Write-Log "网页自动登录失败(教学区): $errmsg [本次ac_id=$acId]"
    $srvmsg = ''
    if ($r.Ok -and $r.Body -match '"error_msg"\s*:\s*"([^"]*)"') { $srvmsg = $Matches[1] }
    $head = if ($r.Body) { $r.Body.Substring(0, [Math]::Min(200, $r.Body.Length)) } else { '(空)' }
    Write-Log "  [login原始返回] $srvmsg | resp头200字: $head"
    return 1
}

# ============================== 主流程 ==============================
function Invoke-Main {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

    $zone = Get-Zone
    if ($DebugNet -and $zone -ne 'none') {
        Write-Log "DEBUG ssid=[$(Get-WifiSSID)] ip=[$(Get-LocalIP)] zone=$zone"
    }
    if ($zone -eq 'none') { return }

    # 在线判定
    if ($zone -eq 'dorm') {
        if (Test-Online) { return }
        if (-not (Test-DormPortal)) {
            Write-Log '外网检测失败且无法连接宿舍认证服务器,疑似网络未就绪,跳过本轮'
            return
        }
    } else {
        $state = Get-TeachState
        if ($state -and $state -ne 'not_online_error') { return }
        if (-not $state -and (Test-Online)) { return }
    }

    # 冷却
    $now = [int](Get-Date -UFormat %s)
    if (Test-Path $LastFile) {
        $last = 0
        [void][int]::TryParse((Get-Content $LastFile -Raw), [ref]$last)
        if ($now - $last -lt $LoginCooldown) { return }
    }

    if (-not (Read-Credentials)) {
        Write-Log "未找到凭据(标识: $CredName)，请先运行 install.ps1 保存账号密码"
        return
    }

    Set-Content -Path $LastFile -Value $now
    Write-Log "检测到断网(区域: $zone),尝试网页自动登录 ..."
    if ($zone -eq 'dorm') { $rc = Login-Dorm } else { $rc = Login-Teach }
    if ($rc -eq 2) {
        # 认证服务器不可达：只做短冷却（20 秒），快速重试
        Set-Content -Path $LastFile -Value ($now - $LoginCooldown + 20)
    }
}

# dot-source（. ./autologin.ps1）时仅加载函数，便于测试；直接运行才执行主流程
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
