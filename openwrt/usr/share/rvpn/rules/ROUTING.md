# Матрица маршрутизации Skvoz

Списки в git (`dpi.txt`, `vpn-domains.txt`, `vpn-cidr.txt`, `games-domains.txt`).  
Ручной shunt на роутере не нужен.

| Ресурс | Слой | Файл |
|--------|------|------|
| Рунет, private | DIRECT | geoip / default |
| Игры (Steam, Epic…) | DIRECT | `games-domains.txt` |
| Rockstar Launcher / Social Club | **VPN** | `vpn-domains.txt` (+ Akamai companions) |
| YouTube (сайт, API, видео, превью) | **VPN** | `vpn-domains.txt` |
| Telegram текст + media/стикеры | **VPN** | `vpn-domains.txt` + `vpn-cidr.txt` |
| SlashLIB / HentaiLIB / MangaLib / atsu.moe | **VPN** | `vpn-domains.txt` |
| Свои домены (быстрый add) | **VPN** | `vpn-user.txt` (`rvpnctl add-domain`) |
| Instagram / Meta / Discord / TikTok / X (+ notify/CDN companions) | **VPN** | `vpn-domains.txt` (+ meta в `vpn-cidr.txt`) |
| Spotify / Twitch / SoundCloud / Reddit | **VPN** | `vpn-domains.txt` |
| Patreon / LinkedIn / Notion / Figma / Canva | **VPN** | `vpn-domains.txt` |
| Apple Music artwork + APNs (`push.apple.com`) | **VPN** | `vpn-domains.txt` |
| Google FCM narrow (`mtalk` / `fcm.*`) — не весь Google | **VPN** | `vpn-domains.txt` |
| Microsoft WNS (`notify.windows.com` / `wns.windows.com`) | **VPN** | `vpn-domains.txt` |
| Gemini / ChatGPT / news | **VPN** | `vpn-domains.txt` (Gemini companions) |
| VPN nodes from subscription (Clash/URI) | **VPN outbounds** | UCI `subscription` + [SUBSCRIPTIONS.md](SUBSCRIPTIONS.md) |
| hdrezka, rutracker, AO3 | **zapret** | `dpi.txt` (nfqws ALT11-like) |
| реклама / трекеры | **Adblock (DNS)** | dnsmasq `address=/…/0.0.0.0` (OISD small + seed/user/allow) |
| остальное | DIRECT | default |

LAN-клиенты (Wi‑Fi/Ethernet) подхватываются сами: DHCP → DNS роутера → nft redirect :53 + FakeIP/TPROXY. Отдельная настройка ПК не нужна (кроме отключённого DoH в браузере).

DNS-адблокер (опционально, UCI `adblock_enabled`): локальные ответы dnsmasq до форварда на FakeIP/sing-box. Список — сбалансированный OISD `small` (`adblock_list_url`), плюс `adblock-user.txt` / исключения `adblock-allow.txt`. Offline seed: `adblock-seed.txt`. CLI: `rvpnctl enable-adblock|disable-adblock|adblock-update|adblock-status`. Cron: `skvoz-adblock` (ежедневно, интервал `adblock_update_hours`).

Почасовой мониторинг нагрузки: cron `skvoz-load` → `/tmp/rvpn/load-hourly.log`, CLI `rvpnctl load`, UI бейджи load/LAN.

Подписки нод: cron `skvoz-sub` (hourly tick → `refresh_hours` / `Profile-Update-Interval`). См. [SUBSCRIPTIONS.md](SUBSCRIPTIONS.md). CLI: `rvpnctl sub-import`, `sub-refresh`, `nodes-probe`, `pool-optimize`.

CIDR (IP→VPN) обновляются раз в неделю (cron `skvoz-cidr`, вс 04:17) и вручную: `rvpnctl sync-cidr` / `sh tools/sync-vpn-cidr.sh`. Источники: Telegram official + ASN Meta/X/Discord/Telegram (ipverse).

## Порядок на роутере

1. DNS adblock (если включён): `address=/bad/0.0.0.0` в dnsmasq — до FakeIP
2. DNS: домены из `vpn-domains.txt` → FakeIP `198.18.0.0/15`
3. nft QUIC: accept FakeIP + `vpn_cidr`, иначе reject UDP/443
4. nft TPROXY: FakeIP + `vpn_cidr` → sing-box → VPS
5. nft zapret: early TCP 80/443 → nfqws **кроме** FakeIP / `vpn_cidr` / mark
6. остальное → WAN напрямую

## Telegram media

Клиент ходит на media DC **по IP**. Неполный `vpn-cidr.txt` = текст есть, фото/видео/стикеры только в части чатов.

Источники: https://core.telegram.org/resources/cidr.txt + ipverse ASN (Meta/X/Discord/Telegram).  
Обновление: `sh tools/sync-vpn-cidr.sh` / на роутере `rvpnctl sync-cidr`.

## Защиты DNS

`filter_aaaa`, блок DoH/DoT (`doh-cidr.txt`), QUIC reject **кроме** FakeIP и `vpn_cidr`.  
Adblock не режет контент внутри YouTube/Telegram — только DNS-домены рекламных сетей.
