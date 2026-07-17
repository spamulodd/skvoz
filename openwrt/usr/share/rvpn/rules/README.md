# rvpn routing lists / Списки маршрутизации

**EN:** Domain and IP lists for Skvoz (rvpn). Shipped in git — deploy to `/usr/share/rvpn/rules/`; no manual editing on the router. See **[ROUTING.md](ROUTING.md)** for the full resource → layer matrix (Russian).

**RU:** Списки доменов и IP для Skvoz. Хранятся в git, деплоятся на роутер — ручной shunt не нужен. Полная матрица «ресурс → слой» — в **[ROUTING.md](ROUTING.md)**.

| File | Layer |
|------|-------|
| `games-domains.txt` | DIRECT (games) |
| `vpn-domains.txt` | VPN FakeIP |
| `vpn-cidr.txt` | VPN IP (Telegram DC/media, Meta); sync: `tools/sync-telegram-cidr.sh` |
| `dpi.txt` | zapret / nfqws (DPI bypass) |
| `doh-hosts.txt` | DoH domains (reference) |
| `doh-cidr.txt` | DoH resolver IPs (reference) |
