# rvpn routing lists / Списки маршрутизации

**EN:** Domain and IP lists for Skvoz (rvpn). Shipped in git — deploy to `/usr/share/rvpn/rules/`; no manual editing on the router. See **[ROUTING.md](ROUTING.md)** for the full resource → layer matrix (Russian).

**RU:** Списки доменов и IP для Skvoz. Хранятся в git, деплоятся на роутер — ручной shunt не нужен. Полная матрица «ресурс → слой» — в **[ROUTING.md](ROUTING.md)**.

| File | Layer |
|------|-------|
| `games-domains.txt` | DIRECT (games) |
| `vpn-domains.txt` | VPN FakeIP (shipped; includes notify/CDN companions) |
| `vpn-user.txt` | VPN FakeIP (quick-add: `rvpnctl add-domain`) |
| `vpn-cidr.txt` | VPN IP (Telegram/Meta/X/Discord ASN); sync: `tools/sync-vpn-cidr.sh` / `rvpnctl sync-cidr` |
| `dpi.txt` | zapret / nfqws (DPI bypass; ALT11-like strategy) |
| `adblock-seed.txt` | DNS adblock offline seed (trackers) |
| `adblock-user.txt` | DNS adblock manual block list |
| `adblock-allow.txt` | DNS adblock allowlist (exceptions) |
| `../fake/*.bin` | nfqws fake TLS/HTTP payloads (max_ru, stun) |
| `doh-hosts.txt` | DoH domains (reference) |
| `doh-cidr.txt` | DoH resolver IPs (reference) |
| `SUBSCRIPTIONS.md` | VPN node subscription import / pool (Clash Meta) |
| `ROUTING.md` | Resource → layer matrix |
