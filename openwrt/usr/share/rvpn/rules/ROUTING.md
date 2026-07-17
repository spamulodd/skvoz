# Матрица маршрутизации Skvoz

Списки в git (`dpi.txt`, `vpn-domains.txt`, `vpn-cidr.txt`, `games-domains.txt`).  
Ручной shunt на роутере не нужен.

| Ресурс | Слой | Файл |
|--------|------|------|
| Рунет, private | DIRECT | geoip / default |
| Игры (Steam, Epic…) | DIRECT | `games-domains.txt` |
| YouTube целиком (сайт, API, видео, превью) | **VPN** | `vpn-domains.txt` |
| Telegram (+ DC/media CIDR) | **VPN** | `vpn-domains.txt` + `vpn-cidr.txt` |
| Instagram / Meta / Discord / TikTok / X | **VPN** | `vpn-domains.txt` (+ meta CIDR) |
| Gemini / ChatGPT / news | **VPN** | `vpn-domains.txt` |
| hdrezka, rutracker | **zapret** | `dpi.txt` |
| остальное | DIRECT | default |

Защиты DNS: `filter_aaaa`, блок DoH/DoT (`doh-cidr.txt`), QUIC reject **кроме** FakeIP и `vpn_cidr`.
