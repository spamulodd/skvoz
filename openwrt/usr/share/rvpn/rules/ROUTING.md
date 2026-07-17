# Матрица rvpn

Порядок: private → games → RU(geoip) → VPN domains/IP → (на WAN) zapret DPI → default DIRECT.

| Ресурс | Слой |
|--------|------|
| ya.ru, vk, банки, Рунет | DIRECT |
| Steam / игровые | DIRECT |
| YouTube / googlevideo | zapret |
| hdrezka, rutracker | zapret |
| Telegram (+ CIDR) | VPN |
| Instagram / Facebook / WA | VPN |
| Discord, TikTok, X | VPN |
| Gemini / ChatGPT | VPN |
| meduza / bbc / dw | VPN |
| остальное | DIRECT |
