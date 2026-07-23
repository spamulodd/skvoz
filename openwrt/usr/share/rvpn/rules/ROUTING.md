# Матрица маршрутизации Skvoz

Списки в git (`dpi.txt`, `vpn-domains.txt`, `vpn-cidr.txt`, `games-domains.txt`).  
Ручной shunt на роутере не нужен.

| Ресурс | Слой | Файл |
|--------|------|------|
| Рунет, private | DIRECT | geoip / default |
| Игры (Steam, Epic…) | DIRECT | `games-domains.txt` |
| Rockstar Launcher / Social Club | **DIRECT + zapret** | `games-domains.txt` + `dpi.txt` (не FakeIP: мёртвые mux.* вешают лаунчер; FB SDK/Graph тоже DIRECT) |
| YouTube + Google (Gemini, gstatic, APIs…) | **VPN** | `vpn-domains.txt` (`google.com` / `googleapis.com` / `youtube.com`…); `mtalk*` → games DIRECT |
| Telegram текст + media/стикеры | **VPN** | `vpn-domains.txt` + `vpn-cidr.txt` |
| SlashLIB / HentaiLIB / MangaLib / atsu.moe | **VPN** | `vpn-domains.txt` |
| Свои домены (быстрый add) | **VPN** | `vpn-user.txt` (`rvpnctl add-domain`) |
| Instagram / Meta / Discord / TikTok / X (+ notify/CDN companions) | **VPN** | `vpn-domains.txt` (+ meta в `vpn-cidr.txt`) |
| Spotify / Twitch / SoundCloud / Reddit | **VPN** | `vpn-domains.txt` |
| Patreon | **FakeIP → нода `role=patreon`** | `patreon-domains.txt` (после sniff; не AEZA — CF 1005/1009) |
| LinkedIn / Notion / Figma / Canva | **VPN** | `vpn-domains.txt` |
| APNs (`push.apple.com`) | **VPN** | `vpn-domains.txt` (ISP DNS часто не резолвит) |
| App Store / Music CDN (`itunes` / `mzstatic` / `apps` / `music.apple.com`) | **DIRECT** | не в VPN — иначе App Store «Не удалось подключиться» |
| Google FCM HTTPS | **VPN** | под `googleapis.com`; **mtalk:5228 DIRECT** (`games-domains.txt`) — иначе Rockstar |
| Microsoft WNS (`notify.windows.com` / `wns.windows.com`) | **VPN** | `vpn-domains.txt` |
| Gemini / ChatGPT / news | **VPN** | `vpn-domains.txt` (Gemini + clients6/gstatic/apis companions — иначе RU DIRECT → geo-block) |
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

Пользовательские списки (UI / quick-add): `vpn-user.txt`, `dpi-user.txt`, `games-user.txt` (+ allow в `adblock-allow.txt`).

## Telegram media

Клиент ходит на media DC **по IP**. Неполный `vpn-cidr.txt` = текст есть, фото/видео/стикеры только в части чатов.

Домены: `telegram.org`, `t.me`, `cdn-telegram.org`, `telesco.pe`, `tg.dev`, `usercontent.dev` и др. в `vpn-domains.txt` (FakeIP).  
Скорость файлов: DC/media IP → `vpn-cidr` **до** sniff (без ожидания 200ms); FakeIP `198.18/15` тоже в `ip_cidr`.  
HY2: `hy2_up_mbps` / `hy2_down_mbps` (по умолчанию **0 = не задавать**; неверные значения портят скорость).  
urltest interval по умолчанию `2m`. OTA после установки **перезапускает** сервис (иначе остаётся старый sing-box.json).
CDN-файлы каналов (>100k) — IP из `149.154.160.0/20` и официального cidr.txt → `vpn-cidr.txt` → nft TPROXY **до** zapret/QUIC-drop.

**Скорость (sing-box), порядок route:** `dns-in`→hijack → `ip_cidr`→VPN → sniff 200ms → `protocol dns` → `ip_is_private`→direct → games→direct → domains→VPN. FakeIP TTL 300s.  
**Важно:** `ip_is_private` нельзя ставить до hijack DNS — иначе FakeIP `127.0.0.42` уходит в direct и DNS ломается.  
**QUIC:** udp/443 reject на WAN, но FakeIP + `vpn_cidr` **accept** — TG через VPN не режется.

Источники: https://core.telegram.org/resources/cidr.txt + ipverse ASN (Meta/X/Discord/Telegram).  
Обновление: `sh tools/sync-vpn-cidr.sh` / на роутере `rvpnctl sync-cidr`.

**Не VPN:** `time100.ru` → только `dpi.txt` (RU DIRECT + nfqws).

## Защиты DNS

`filter_aaaa`, блок DoH/DoT (`doh-cidr.txt`), QUIC reject **кроме** FakeIP и `vpn_cidr`.  
Adblock не режет контент внутри YouTube/Telegram — только DNS-домены рекламных сетей.

## FakeIP и NXDOMAIN

sing-box FakeIP отвечает синтетическим `198.18.x` на **любой** запрос, попавший под `domain_suffix` из `vpn-domains.txt`, даже если имя в реальности NXDOMAIN. Клиенты (лаунчеры) могут бесконечно висеть на SynSent.

Правила:
1. Широкие apex в VPN — только для живых сервисов; мёртвые/служебные subdomain’ы платформ → `games-domains.txt` (DNS `local` + route DIRECT).
2. DNS: `games_dom` → `local` **до** правила FakeIP; route: games DIRECT до VPN.
3. Не класть в VPN суффиксы вроде целого `google.com` / `googleapis.com` — только узкие companions.
