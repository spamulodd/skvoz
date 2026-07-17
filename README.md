# Skvoz

Гибридный обход блокировок для OpenWrt: **zapret** (DPI) + узкий **VPN** (hard-block).  
Рунет и игры — напрямую.

## Матрица

| Слой | Ресурсы |
|------|---------|
| **DIRECT** | Рунет, private, игры, всё остальное |
| **zapret** | YouTube, hdrezka, rutracker |
| **VPN** | Telegram (+ DC CIDR), Instagram/Meta, Discord, TikTok, X, Gemini, ChatGPT, news |

FakeIP только для VPN-доменов; Telegram DC/Meta IP уходят в TPROXY по CIDR.

## Требования

- OpenWrt 24+/25.x, `sing-box`
- `nfqws` (mipsel и др.) → `/opt/rvpn/nfqws`
- `libnetfilter-queue`, `kmod-nft-queue`, `kmod-nft-tproxy`

## Установка

1. Скопируй дерево `openwrt/` на роутер (см. `tools/deploy.ps1`).
2. Пропиши ноду в `/etc/config/rvpn` (пароль/сервер).
3. Положи `nfqws` в `/opt/rvpn/nfqws`.
4. UI: `http://ROUTER:81/` — нужен `ui_secret` (`uci get rvpn.main.ui_secret`).
5. Clash API только на `127.0.0.1:9090` + secret; CGI требует токен.

```sh
rvpnctl status
rvpnctl enable-zapret
rvpnctl enable-vpn
```

YouTube превью/иконки: dpi-hostlist + `disable_quic=1` (UDP/443 с LAN режется, клиент идёт по TCP через zapret).

## Лицензия

MIT
