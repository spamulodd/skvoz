# Skvoz

Гибридный обход блокировок для OpenWrt: **zapret** (обход DPI через nfqws) + узкий **VPN** (sing-box) для жёстко заблокированных сервисов. Рунет, игры и прочий трафик — напрямую.

Репозиторий: https://github.com/spamulodd/skvoz

## Матрица маршрутизации

Списки доменов и IP **лежат в git** (`openwrt/usr/share/rvpn/rules/`) и подхватываются при установке — **ручной shunt на роутере не нужен**.

| Слой | Ресурсы |
|------|---------|
| **DIRECT** | Рунет (geoip), private, игры, всё остальное |
| **zapret** | YouTube (видео/плеер), hdrezka, rutracker |
| **VPN** | Telegram (+ DC CIDR), Instagram/Meta, Discord, TikTok, X, Gemini, ChatGPT, новости |

Подробная матрица, порядок обработки и файлы списков: [`openwrt/usr/share/rvpn/rules/ROUTING.md`](openwrt/usr/share/rvpn/rules/ROUTING.md).

## YouTube

| Что | Слой | Список |
|-----|------|--------|
| Видео, плеер, `googlevideo.com` | zapret (nfqws) | `dpi.txt` |
| Превью, аватарки, community (`ytimg`, `ggpht`, `googleusercontent`) | VPN FakeIP | `vpn-domains.txt` |

Домены **не дублируются** между `dpi.txt` и `vpn-domains.txt`.

Дополнительно при включённом zapret или VPN:

- **filter-aaaa** в dnsmasq — клиенты не уходят на IPv6 в обход правил
- **блок DoH/DoT** (nft по `doh-cidr.txt`) — браузер использует DNS роутера

## Требования

- OpenWrt 24+/25.x
- `sing-box` (для VPN-слоя)
- `nfqws` под вашу CPU → `/opt/rvpn/nfqws` (бинарник не входит в пакет)
- `libnetfilter-queue`, `kmod-nft-queue`, `kmod-nft-tproxy`

## Установка

Скрипты и списки **не зависят от архитектуры**; `nfqws` кладётся отдельно.

### Скрипт `tools/install.sh` (apk/opkg автоматически)

```sh
git clone https://github.com/spamulodd/skvoz.git && cd skvoz
sh tools/install.sh
```

Через tarball: `SKVOZ_TARBALL=/tmp/skvoz-*.tar.gz sh tools/install.sh`

### `.ipk` без SDK — `tools/mkipk.sh`

```sh
sh tools/mkipk.sh                    # → dist/skvoz_*_all.ipk
opkg install /tmp/skvoz_*_all.ipk
```

### Пакет из OpenWrt SDK — `package/skvoz/Makefile`

```sh
# скопируйте package/skvoz и openwrt/ в дерево SDK
make package/skvoz/compile V=s
apk add --allow-untrusted bin/packages/*/base/skvoz_*.apk   # OpenWrt 25+
# или opkg install … на старых версиях
```

## После установки

1. Отредактируйте `/etc/config/rvpn`: замените плейсхолдеры `YOUR_VPS_IP`, `YOUR_HY2_PASSWORD` (и при необходимости `ui_secret`).
2. Положите `nfqws` в `/opt/rvpn/nfqws` (`chmod +x`).
3. Веб-UI: `http://ROUTER:81/` — пароль: `uci get rvpn.main.ui_secret`.
4. Слои **выключены** по умолчанию; init.d `rvpn` включён, но zapret/VPN не поднимает.

```sh
rvpnctl enable-zapret    # после nfqws
rvpnctl enable-vpn       # после настройки ноды и sing-box
```

## `rvpnctl`

| Команда | Действие |
|---------|----------|
| `rvpnctl status` | Состояние слоёв, процессы, nft |
| `rvpnctl start` / `stop` / `restart` | Управление сервисом |
| `rvpnctl enable-zapret` / `disable-zapret` | Вкл/выкл zapret |
| `rvpnctl enable-vpn` / `disable-vpn` | Вкл/выкл VPN |
| `rvpnctl gen-config` | Пересобрать sing-box.json |
| `rvpnctl log [N]` | Последние N строк лога (по умолчанию 80) |

## Лицензия

MIT — см. [LICENSE](LICENSE).
