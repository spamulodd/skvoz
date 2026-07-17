# Deploy rvpn to OpenWrt via plink (no SFTP).
param(
  [string]$RouterHost = "192.168.1.1",
  [string]$User = "root",
  [string]$Password = "",
  [string]$Plink = "plink"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$OpenWrt = Join-Path $Root "openwrt"

if (-not $Password) {
  $sec = Read-Host "Router password" -AsSecureString
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Invoke-Router([string]$Cmd) {
  & $Plink -batch -ssh "$User@$RouterHost" -pw $Password $Cmd
  if ($LASTEXITCODE -ne 0) { throw "plink failed: $Cmd" }
}

function Send-TextFile([string]$LocalPath, [string]$RemotePath) {
  $bytes = [IO.File]::ReadAllBytes($LocalPath)
  # normalize CRLF -> LF for shell scripts
  $text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n" -replace "`r", "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
  # chunk to avoid command line limits
  $chunkSize = 1200
  Invoke-Router "rm -f '$RemotePath' '$RemotePath.b64'"
  for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $b64.Length - $i)
    $part = $b64.Substring($i, $len)
    Invoke-Router "printf '%s' '$part' >> '$RemotePath.b64'"
  }
  Invoke-Router "base64 -d '$RemotePath.b64' > '$RemotePath' && rm -f '$RemotePath.b64'"
}

Write-Host "Preparing remote dirs..."
Invoke-Router "mkdir -p /usr/lib/rvpn /usr/share/rvpn/rules /usr/share/rvpn/bin /opt/rvpn /www/rvpn/cgi-bin /tmp/rvpn /etc/config"

$files = @(
  @{ L = "etc\config\rvpn"; R = "/etc/config/rvpn" },
  @{ L = "etc\init.d\rvpn"; R = "/etc/init.d/rvpn" },
  @{ L = "usr\bin\rvpnctl"; R = "/usr/bin/rvpnctl" },
  @{ L = "usr\lib\rvpn\common.sh"; R = "/usr/lib/rvpn/common.sh" },
  @{ L = "usr\lib\rvpn\dns.sh"; R = "/usr/lib/rvpn/dns.sh" },
  @{ L = "usr\lib\rvpn\nft.sh"; R = "/usr/lib/rvpn/nft.sh" },
  @{ L = "usr\lib\rvpn\singbox.sh"; R = "/usr/lib/rvpn/singbox.sh" },
  @{ L = "usr\lib\rvpn\zapret.sh"; R = "/usr/lib/rvpn/zapret.sh" },
  @{ L = "usr\lib\rvpn\health.sh"; R = "/usr/lib/rvpn/health.sh" },
  @{ L = "usr\share\rvpn\rules\dpi.txt"; R = "/usr/share/rvpn/rules/dpi.txt" },
  @{ L = "usr\share\rvpn\rules\vpn-domains.txt"; R = "/usr/share/rvpn/rules/vpn-domains.txt" },
  @{ L = "usr\share\rvpn\rules\games-domains.txt"; R = "/usr/share/rvpn/rules/games-domains.txt" },
  @{ L = "www\rvpn\index.html"; R = "/www/rvpn/index.html" },
  @{ L = "www\rvpn\cgi-bin\rvpn.cgi"; R = "/www/rvpn/cgi-bin/rvpn.cgi" }
)

foreach ($f in $files) {
  $lp = Join-Path $OpenWrt $f.L
  Write-Host "Upload $($f.L) -> $($f.R)"
  Send-TextFile $lp $f.R
}

# optional nfqws binary (mipsel)
$nfqLocal = Join-Path $OpenWrt "usr\share\rvpn\bin\nfqws"
if (Test-Path $nfqLocal) {
  Write-Host "Upload nfqws binary..."
  $bytes = [IO.File]::ReadAllBytes($nfqLocal)
  $b64 = [Convert]::ToBase64String($bytes)
  Invoke-Router "rm -f /tmp/nfqws.b64 /opt/rvpn/nfqws"
  $chunkSize = 900
  for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $b64.Length - $i)
    $part = $b64.Substring($i, $len)
    Invoke-Router "printf '%s' '$part' >> /tmp/nfqws.b64"
  }
  Invoke-Router "base64 -d /tmp/nfqws.b64 > /opt/rvpn/nfqws && chmod +x /opt/rvpn/nfqws && cp -f /opt/rvpn/nfqws /usr/share/rvpn/bin/nfqws"
}

Write-Host "Permissions + uhttpd :81..."
$remoteSetup = @'
chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi /usr/lib/rvpn/*.sh
# deps for nfqws (ignore if already present)
apk add libnetfilter-queue1 libnfnetlink0 kmod-nfnetlink-queue kmod-nft-queue kmod-nft-tproxy kmod-nft-socket 2>/dev/null || true
# fresh deploy leaves switches OFF for safety
uci set rvpn.main.zapret_enabled=0
uci set rvpn.main.vpn_enabled=0
uci commit rvpn

# uhttpd instance for UI
uci -q delete uhttpd.rvpn
uci set uhttpd.rvpn=uhttpd
uci set uhttpd.rvpn.listen_http='0.0.0.0:81'
uci set uhttpd.rvpn.home='/www/rvpn'
uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
uci set uhttpd.rvpn.script_timeout='120'
uci set uhttpd.rvpn.network_timeout='60'
uci set uhttpd.rvpn.tcp_keepalive='1'
uci set uhttpd.rvpn.rfc1918_filter='0'
uci set uhttpd.rvpn.max_requests='40'
uci commit uhttpd
/etc/init.d/uhttpd restart
/etc/init.d/rvpn enable
/etc/init.d/rvpn stop
echo DEPLOY_OK
ping -c1 -W2 192.168.100.1 >/dev/null && echo WAN_OK || ping -c1 -W2 1.1.1.1 >/dev/null && echo WAN_OK || echo WAN_BAD
which sing-box
sing-box version 2>/dev/null | head -1
ls -la /opt/rvpn /usr/share/rvpn/bin 2>/dev/null
'@

# send setup via base64 too
$setupPath = Join-Path $env:TEMP "rvpn-remote-setup.sh"
[IO.File]::WriteAllText($setupPath, ($remoteSetup -replace "`r`n", "`n"))
Send-TextFile $setupPath "/tmp/rvpn-remote-setup.sh"
Invoke-Router "sh /tmp/rvpn-remote-setup.sh"

Write-Host ""
Write-Host "Done. UI: http://$RouterHost`:81/  (both toggles OFF)"
Write-Host "Next: put nfqws (mipsel) to /opt/rvpn/nfqws then: rvpnctl enable-zapret"
Write-Host "VPN: rvpnctl enable-vpn"
