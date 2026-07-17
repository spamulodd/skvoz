# Матрица маршрутизации Skvoz

Списки в git (`dpi.txt`, `vpn-domains.txt`, `vpn-cidr.txt`, `games-domains.txt`).  
Ручной shunt на роутере не нужен.

| Ресурс | Слой | Файл |
|--------|------|------|
| Рунет, private | DIRECT | geoip / default |
| Игры (Steam, Epic…) | DIRECT | `games-domains.txt` |
| YouTube (сайт, API, видео, превью) | **VPN** | `vpn-domains.txt` |
| Telegram текст + media/стикеры | **VPN** | `vpn-domains.txt` + `vpn-cidr.txt` |
| Instagram / Meta / Discord / TikTok / X | **VPN** | `vpn-domains.txt` (+ meta в `vpn-cidr.txt`) |
| Gemini / ChatGPT / news | **VPN** | `vpn-domains.txt` |
| hdrezka, rutracker | **zapret** | `dpi.txt` |
| остальное | DIRECT | default |

## Порядок на роутере

1. DNS: домены из `vpn-domains.txt` → FakeIP `198.18.0.0/15`
2. nft QUIC: accept FakeIP + `vpn_cidr`, иначе reject UDP/443
3. nft TPROXY: FakeIP + `vpn_cidr` → sing-box → VPS
4. nft zapret: early TCP 80/443 → nfqws **кроме** FakeIP / `vpn_cidr` / mark
5. остальное → WAN напрямую

## Telegram media

Клиент ходит на media DC **по IP**. Неполный `vpn-cidr.txt` = текст есть, фото/видео/стикеры только в части чатов.

Источник IPv4: https://core.telegram.org/resources/cidr.txt  
Обновление в репозитории: `sh tools/sync-telegram-cidr.sh`

## Защиты DNS

`filter_aaaa`, блок DoH/DoT (`doh-cidr.txt`), QUIC reject **кроме** FakeIP и `vpn_cidr`.
