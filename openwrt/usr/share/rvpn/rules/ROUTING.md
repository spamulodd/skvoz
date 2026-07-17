# Маршрутизация Skvoz (rvpn)

Списки доменов и IP **лежат в git** (`openwrt/usr/share/rvpn/rules/`) и подхватываются при деплое — **ручной shunt на роутере не нужен**. После обновления репозитория достаточно задеплоить пакет и перезапустить rvpn.

## Порядок обработки трафика

```
private → games → RU (geoip) → VPN (FakeIP + CIDR) → (на WAN) zapret / nfqws → default DIRECT
```

| Слой | Файл | Что делает |
|------|------|------------|
| DIRECT (игры) | `games-domains.txt` | Steam, консоли, античит — всегда напрямую |
| DIRECT (RU) | geoip (не в списках) | Рунет, банки, vk, ya.ru и т.п. |
| VPN FakeIP | `vpn-domains.txt` | Жёстко заблокированные сервисы → sing-box |
| VPN CIDR | `vpn-cidr.txt` | IP Telegram + Meta → tproxy (nft auto-merge) |
| zapret / nfqws | `dpi.txt` | DPI на реальных IP: YouTube **видео/плеер**, hdrezka, rutracker |
| DoH (справочно) | `doh-hosts.txt`, `doh-cidr.txt` | Публичные DoH — для аудита / будущих правил |
| default | — | Всё остальное → DIRECT |

## Матрица: ресурс → слой

| Ресурс | Слой | Файл |
|--------|------|------|
| Рунет (ya.ru, vk, банки, госуслуги…) | DIRECT | geoip |
| Steam, Epic, Riot, Blizzard, консоли | DIRECT | `games-domains.txt` |
| YouTube **видео**, плеер, `googlevideo.com` | zapret | `dpi.txt` |
| YouTube **превью**, аватарки, community (`ytimg`, `ggpht`, `googleusercontent`) | VPN FakeIP | `vpn-domains.txt` |
| hdrezka, rutracker, nnmclub | zapret | `dpi.txt` |
| Telegram | VPN + CIDR | `vpn-domains.txt` + `vpn-cidr.txt` |
| Instagram, Facebook, WhatsApp, Threads | VPN + CIDR | `vpn-domains.txt` + `vpn-cidr.txt` |
| Discord, TikTok, X (Twitter) | VPN FakeIP | `vpn-domains.txt` |
| Gemini, ChatGPT, Claude, Copilot и др. AI | VPN FakeIP | `vpn-domains.txt` |
| meduza, BBC, DW, Guardian и др. новости | VPN FakeIP | `vpn-domains.txt` |
| Браузерный DoH (dns.google, cloudflare-dns…) | справочно | `doh-hosts.txt` / `doh-cidr.txt` |
| Всё остальное | DIRECT | default |

## Важно

- **Не дублировать** домены между `dpi.txt` и `vpn-domains.txt`. Видео/CDN плеера — только в `dpi.txt`; картинки YouTube — только в `vpn-domains.txt`.
- `dpi.txt` — это **обход DPI** (nfqws), а не список IP-банов.
- `vpn-cidr.txt` — только стабильные диапазоны Telegram и Meta; пересечения nft схлопывает (`auto-merge`).

## Файлы

| Файл | Назначение |
|------|------------|
| `dpi.txt` | Hostlist для nfqws / zapret |
| `vpn-domains.txt` | FakeIP sing-box (domain_suffix) |
| `vpn-cidr.txt` | tproxy по IP (Telegram, Meta) |
| `games-domains.txt` | Исключения → direct |
| `doh-hosts.txt` | Домены публичного DoH |
| `doh-cidr.txt` | IP публичных DoH-резолверов |
