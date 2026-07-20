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
  @{ L = "usr\lib\rvpn\zapret-strat.sh"; R = "/usr/lib/rvpn/zapret-strat.sh" },
  @{ L = "usr\lib\rvpn\zapret-sync.sh"; R = "/usr/lib/rvpn/zapret-sync.sh" },
  @{ L = "usr\lib\rvpn\zapret-test.sh"; R = "/usr/lib/rvpn/zapret-test.sh" },
  @{ L = "usr\lib\rvpn\nfqws-fetch.sh"; R = "/usr/lib/rvpn/nfqws-fetch.sh" },
  @{ L = "usr\lib\rvpn\update.sh"; R = "/usr/lib/rvpn/update.sh" },
  @{ L = "usr\lib\rvpn\selftest.sh"; R = "/usr/lib/rvpn/selftest.sh" },
  @{ L = "usr\lib\rvpn\adblock.sh"; R = "/usr/lib/rvpn/adblock.sh" },
  @{ L = "usr\lib\rvpn\health.sh"; R = "/usr/lib/rvpn/health.sh" },
  @{ L = "usr\lib\rvpn\cidr-sync.sh"; R = "/usr/lib/rvpn/cidr-sync.sh" },
  @{ L = "usr\lib\rvpn\watchdog.sh"; R = "/usr/lib/rvpn/watchdog.sh" },
  @{ L = "usr\lib\rvpn\sub.sh"; R = "/usr/lib/rvpn/sub.sh" },
  @{ L = "usr\lib\rvpn\node-pool.sh"; R = "/usr/lib/rvpn/node-pool.sh" },
  @{ L = "usr\lib\rvpn\ui-api.sh"; R = "/usr/lib/rvpn/ui-api.sh" },
  @{ L = "usr\lib\rvpn\clash-parse.awk"; R = "/usr/lib/rvpn/clash-parse.awk" },
  @{ L = "usr\lib\rvpn\sub-filter.awk"; R = "/usr/lib/rvpn/sub-filter.awk" },
  @{ L = "usr\share\rvpn\VERSION"; R = "/usr/share/rvpn/VERSION" },
  @{ L = "usr\share\rvpn\rules\categories.json"; R = "/usr/share/rvpn/rules/categories.json" },
  @{ L = "usr\share\rvpn\rules\dpi.txt"; R = "/usr/share/rvpn/rules/dpi.txt" },
  @{ L = "usr\share\rvpn\rules\dpi-user.txt"; R = "/usr/share/rvpn/rules/dpi-user.txt" },
  @{ L = "usr\share\rvpn\rules\adblock-seed.txt"; R = "/usr/share/rvpn/rules/adblock-seed.txt" },
  @{ L = "usr\share\rvpn\rules\adblock-user.txt"; R = "/usr/share/rvpn/rules/adblock-user.txt" },
  @{ L = "usr\share\rvpn\rules\adblock-allow.txt"; R = "/usr/share/rvpn/rules/adblock-allow.txt" },
  @{ L = "usr\share\rvpn\rules\vpn-domains.txt"; R = "/usr/share/rvpn/rules/vpn-domains.txt" },
  @{ L = "usr\share\rvpn\rules\vpn-cidr.txt"; R = "/usr/share/rvpn/rules/vpn-cidr.txt" },
  @{ L = "usr\share\rvpn\rules\games-domains.txt"; R = "/usr/share/rvpn/rules/games-domains.txt" },
  @{ L = "usr\share\rvpn\rules\games-user.txt"; R = "/usr/share/rvpn/rules/games-user.txt" },
  @{ L = "usr\share\rvpn\rules\ROUTING.md"; R = "/usr/share/rvpn/rules/ROUTING.md" },
  @{ L = "usr\share\rvpn\rules\SUBSCRIPTIONS.md"; R = "/usr/share/rvpn/rules/SUBSCRIPTIONS.md" },
  @{ L = "usr\share\rvpn\rules\README.md"; R = "/usr/share/rvpn/rules/README.md" },
  @{ L = "www\rvpn\index.html"; R = "/www/rvpn/index.html" },
  @{ L = "www\rvpn\cgi-bin\rvpn.cgi"; R = "/www/rvpn/cgi-bin/rvpn.cgi" }
)

foreach ($f in $files) {
  $lp = Join-Path $OpenWrt $f.L
  Write-Host "Upload $($f.L) -> $($f.R)"
  Send-TextFile $lp $f.R
}

function Send-BinaryFile([string]$LocalPath, [string]$RemotePath) {
  $bytes = [IO.File]::ReadAllBytes($LocalPath)
  $b64 = [Convert]::ToBase64String($bytes)
  $tmpB64 = "$RemotePath.b64"
  Invoke-Router "rm -f '$RemotePath' '$tmpB64'"
  $chunkSize = 900
  for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $b64.Length - $i)
    $part = $b64.Substring($i, $len)
    Invoke-Router "printf '%s' '$part' >> '$tmpB64'"
  }
  Invoke-Router "base64 -d '$tmpB64' > '$RemotePath' && rm -f '$tmpB64'"
}

# Flowseal fake TLS/HTTP/QUIC payloads for nfqws
Invoke-Router "mkdir -p /usr/share/rvpn/fake /usr/share/rvpn/zapret-strategies/lists"
foreach ($bin in @(
  "stun.bin",
  "tls_clienthello_max_ru.bin",
  "tls_clienthello_www_google_com.bin",
  "tls_clienthello_4pda_to.bin",
  "quic_initial_www_google_com.bin",
  "quic_initial_dbankcloud_ru.bin"
)) {
  $lp = Join-Path $OpenWrt "usr\share\rvpn\fake\$bin"
  if (Test-Path $lp) {
    Write-Host "Upload fake/$bin"
    Send-BinaryFile $lp "/usr/share/rvpn/fake/$bin"
  }
}

# Flowseal strategies + lists (text)
$stratLocal = Join-Path $OpenWrt "usr\share\rvpn\zapret-strategies"
Get-ChildItem $stratLocal -Filter "*.strategy" | ForEach-Object {
  Write-Host "Upload strategy $($_.Name)"
  Send-TextFile $_.FullName "/usr/share/rvpn/zapret-strategies/$($_.Name)"
}
foreach ($meta in @("INDEX", "META.json")) {
  $mp = Join-Path $stratLocal $meta
  if (Test-Path $mp) {
    Send-TextFile $mp "/usr/share/rvpn/zapret-strategies/$meta"
  }
}
foreach ($lst in @("list-general.txt", "list-exclude.txt", "list-google.txt", "ipset-exclude.txt", "ipset-all.txt")) {
  $lp = Join-Path $stratLocal "lists\$lst"
  if (Test-Path $lp) {
    Write-Host "Upload lists/$lst"
    Send-TextFile $lp "/usr/share/rvpn/zapret-strategies/lists/$lst"
  }
}
Invoke-Router "uci -q get rvpn.main.zapret_strategy >/dev/null || uci set rvpn.main.zapret_strategy=general_alt11; uci commit rvpn"

# optional nfqws binary (mipsel)
$nfqLocal = Join-Path $OpenWrt "usr\share\rvpn\bin\nfqws"
if (Test-Path $nfqLocal) {
  Write-Host "Upload nfqws binary..."
  Send-BinaryFile $nfqLocal "/opt/rvpn/nfqws"
  Invoke-Router "chmod +x /opt/rvpn/nfqws && mkdir -p /usr/share/rvpn/bin && cp -f /opt/rvpn/nfqws /usr/share/rvpn/bin/nfqws"
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
