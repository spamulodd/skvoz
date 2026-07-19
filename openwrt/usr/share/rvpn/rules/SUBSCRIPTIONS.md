# Subscriptions (VPN node pool)

Conflux-inspired pipeline on the router:

```
fetch → expand (Clash YAML / Base64 URI) → parse → prefer/filter → UCI nodes
→ sing-box outbounds + urltest → optional Clash API probe / pool-optimize
```

## Enable a subscription

1. Set URL (keep tokens out of git):

```sh
uci set rvpn.sub1.url='https://YOUR_PANEL/TOKEN'
uci set rvpn.sub1.enabled='1'
uci commit rvpn
```

2. Import (writes `config node` with `source='sub:sub1'`):

```sh
rvpnctl sub-import sub1
# or: rvpnctl sub-refresh sub1
```

3. Turn VPN on (or restart if already running):

```sh
rvpnctl enable-vpn
# optional latency prune:
rvpnctl pool-optimize
rvpnctl restart
```

## UCI knobs

| Option | Where | Meaning |
|--------|--------|---------|
| `url` | `subscription` | HTTPS subscription endpoint |
| `ua` | `subscription` | User-Agent (default `clash.meta`) |
| `refresh_hours` | `subscription` | Cron refresh interval; also updated from `Profile-Update-Interval` |
| `max_nodes` | `subscription` | Cap after prefer ranking (default 24) |
| `prefer` | `subscription` | Comma tokens: `vless-reality,hysteria2,trojan,vless-ws,vless-grpc,vless,ss` |
| `skip_keywords` | `subscription` | Drop info/expire rows by tag substring |
| `pool_keep` | `main` | How many alive nodes to keep enabled after probe |
| `pool_min_alive` | `main` | Below this → fallback re-enable by UCI `priority` |
| `pool_probe_timeout_ms` | `main` | Clash API `/proxies/{tag}/delay` timeout |

## CLI

| Command | Action |
|---------|--------|
| `rvpnctl sub-import <id>` | Fetch/parse/filter → UCI |
| `rvpnctl sub-refresh [id]` | One id or all enabled |
| `rvpnctl nodes-probe` | Clash API delay table |
| `rvpnctl pool-optimize` | Probe + enable best / disable dead |

## Cron

`health_cron_install` adds hourly `skvoz-sub` → `sub_cron_tick`, which refreshes only when `refresh_hours` elapsed (from UCI or subscription header). Cron is restarted only if the crontab file changed.

## Formats

- **Clash Meta YAML** (primary; OverSecure-like panels)
- **Base64 / plaintext URI** lists: `vless`, `hy2`/`hysteria2`, `trojan`, `ss`

Parser: `clash-parse.awk` + `sub.sh`. Outbounds: `singbox.sh` (hy2, vless Reality/ws/grpc, trojan, ss).
