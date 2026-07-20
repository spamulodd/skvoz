# Skvoz release editions (flash / RAM)

Все edition — **arch-independent** tarball (`openwrt/` tree). Бинарь `nfqws` **никогда не кладётся** в архив: ставится на роутере по CPU (`rvpnctl nfqws-fetch` / install).

| Edition | Файл | Для кого | Примерный размер* | Что внутри |
|---------|------|----------|-------------------|------------|
| **tiny** | `skvoz-VERSION-tiny.tar.gz` | 8–16 MB flash, почти нет места | ~180–220 KB | Код + 1 стратегия (`general_alt11`) + минимальные списки доменов. Flowseal lists / лишние fake — скачать после VPN. |
| **slim** | `skvoz-VERSION-slim.tar.gz` | 16–32 MB flash | ~230–280 KB | + 4 стратегии, list-general, основные fake TLS. Без длинных .md. |
| **standard** | `skvoz-VERSION-standard.tar.gz` | 32 MB+ / обычный роутер | ~300–380 KB | Все 20 стратегий Flowseal + lists + fake. Docs урезаны. |
| **full** | `skvoz-VERSION-full.tar.gz` | USB/флешка, запас места | ~350–450 KB | Всё: стратегии, lists, fake, ROUTING.md / SUBSCRIPTIONS.md. |

\*gzip tarball без `nfqws` и без `_raw_bats`. Точный размер — в assets релиза.

## Как ставить

```sh
# по умолчанию install.sh берёт standard
curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh

# явно:
SKVOZ_EDITION=tiny   curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh
SKVOZ_EDITION=slim   curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh
SKVOZ_EDITION=full   curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh

# или прямой URL ассета
SKVOZ_URL='https://github.com/spamulodd/skvoz/releases/download/v0.2.0/skvoz-0.2.0-slim.tar.gz' sh install.sh
```

## Обновления через VPN

После включения VPN загрузки с GitHub идут через local mixed-proxy (`127.0.0.1:10808`): `rvpnctl update`, списки Flowseal, `nfqws-fetch`.

## После tiny/slim

1. Настроить VPN в мастере UI  
2. `rvpnctl zapret-sync` / кнопка «Списки» — докачает Flowseal  
3. `rvpnctl nfqws-fetch` — если бинарь ещё не встал  
4. При желании `rvpnctl update` с edition побольше (overlay update)

## Что никогда не режем

- `/usr/lib/rvpn/*.sh`, CGI, `rvpnctl`, init.d  
- UI (`index.html`) — мастер нужен всем  
- `vpn-domains.txt`, `dpi.txt`, `games-domains.txt`, user stubs  
- `categories.json`

## Сборка

```sh
sh tools/build-release.sh 0.2.0
# → dist/skvoz-0.2.0-{tiny,slim,standard,full}.tar.gz
# → dist/RELEASE-NOTES-0.2.0.md
```
