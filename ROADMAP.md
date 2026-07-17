# Skvoz — roadmap и заметки для контрибьюторов

Что уже есть: гибрид **zapret + VPN**, git-списки, FakeIP/CIDR, UI на `:81`, fail-open (частично), `rvpnctl`, установка apk/opkg.

Ниже — идеи для других пользователей и долги после code review (без реализации в этом файле).

---

## Идеи функционала (по пользе)

### Must-have для чужого роутера

1. **Мастер первой настройки в UI**  
   Ввод VPS / HY2 / Reality, проверка `sing-box check`, кнопка «включить VPN», копирование `ui_secret`. Без SSH большинство не дойдёт.

2. **Импорт ноды из URI / Clash / sing-box JSON**  
   `hy2://`, `vless://`, вставка outbound-блока. Сейчас только UCI вручную.

3. **Настоящий fail-open DNS**  
   FakeIP только пока sing-box жив; при падении — сразу обычный upstream (+ `filter_aaaa` если zapret). См. Known issues #1–2.

4. **Обновление списков с GitHub**  
   Кнопка / cron: `vpn-domains`, `vpn-cidr`, `dpi` с релиза или `raw.githubusercontent.com`. Плюс `sync-telegram-cidr` на роутере.

5. **Профили маршрутизации**  
   Пресеты: «минимум» (TG+YT), «соцсети», «макс». Переключение без ручного редактирования txt.

### Сильно желательно

6. **Диагностика в UI**  
   WAN OK, ping ноды, FakeIP для `youtube.com` / `telegram.org`, счётчики nft tproxy, хвост лога, «почему этот сайт не в VPN».

7. **Несколько нод + urltest в UI**  
   Добавить/удалить outbound, выбрать primary, видеть delay (Clash API уже на `127.0.0.1:9090`).

8. **Per-device / per-MAC исключения**  
   Телевизор / приставка / IoT → DIRECT (или наоборот только телефон в VPN). Через ipset + nft.

9. **LAN-only UI по умолчанию**  
   Слушать `br-lan` / `192.168.1.1:81`, не `0.0.0.0`; токен не в query string.

10. **Опциональный geosite/geoip**  
    Подтягивать `geosite-telegram` / `geoip-cn` rule-set в sing-box для тех, кому мало txt-списков.

11. **Split DNS / split routing FAQ**  
    Готовый блок «банк РФ direct, Discord VPN» + предупреждение про `googleusercontent.com` (широкий суффикс).

12. **Авто-бэкап UCI + списков**  
    Перед апгрейдом пакета; не сбрасывать `vpn_enabled` на upgrade (сейчас postinst гасит слои).

### Nice to have

13. Луа/Prometheus метрики, webhook «нода упала».  
14. IPv6-путь (сейчас сознательно filter_aaaa).  
15. Готовые образы/сборки под популярные SoC + `nfqws` в релизе.  
16. Мультиязычный UI (EN).  
17. Режим «только zapret» / «только VPN» с понятными предупреждениями в UI.

---

## Known issues (code review)

Исправлено в дереве (см. коммиты после `2c8fa0c`): fail-open DNS, LAN UI, `chmod 600`, токен только в заголовке, `flock`, DNS backup/`localuse`, kill только своего nfqws, upgrade не гасит слои, `insecure=0`, валидация CIDR/доменов/портов, `tools/test-unit.sh`.

Остаётся на будущее:

| Sev | Проблема | Где |
|-----|----------|-----|
| Medium | TPROXY inbound всё ещё `0.0.0.0` (нужен firewall wan drop) | `singbox.sh` |
| Low | Широкий `googleusercontent.com` в VPN | `vpn-domains.txt` |
| Low | Полные интеграционные тесты на роутере (mock uci/nft) | `tools/` |

### Что уже хорошо

- QUIC reject пропускает FakeIP и `vpn_cidr` (иначе ломаются YT/TG media).
- Zapret queue с `bypass`; nft zapret не трогает FakeIP/CIDR/mark.
- Stop: flush nft до kill процессов; Clash API только localhost.
- Слои по умолчанию выключены; `sing-box check` перед запуском; PID scoped к своему JSON.

---

## Предлагаемый порядок работ

1. Починить fail-open DNS (#1–2) + тест сценария «убить sing-box».  
2. UI bind + токен не в URL + `chmod 600` на JSON.  
3. Мастер настройки + импорт URI.  
4. Обновление списков с git + диагностика в UI.  
5. Профили и per-device исключения.
