# 3x-ui-vpn — навык для VPN-сервера на VPS

Навык для агента (Hermes Agent, DeepSeek, Qwen, Claude — любой, кто читает `SKILL.md`
и умеет вызывать shell), который доводит VPS до рабочего VPN: укрепление ОС,
3x-ui, VLESS Reality (или TLS), проверка подключения на живом трафике.
Плюс вторая половина, которой не было раньше: аудит и ремонт уже работающего сервера.

**В файлах навыка нет и не должно быть ни одного реального IP, пароля, ключа или
готовой ссылки.** Только плейсхолдеры вида `<SERVER_IP>`, `<UUID>`, `<PBK>`.

---

## Что нового в 3.1

Эксплуатация вместо разовой настройки: клиенты, подписка, сторож, бэкапы, тесты.

| Задача | Что появилось |
|---|---|
| Выдать клиента с лимитами | `scripts/add_client.sh`: срок, трафик, лимит IP, `subId`, ссылка и URL подписки |
| Ссылки обновлялись сами | `scripts/sub_setup.sh`: подписка включена и проверена запросом |
| «Что реально сделано» | `scripts/state_check.sh`: PASS/WARN/FAIL по факту, `--json`, `--strict` |
| Узнать о падении первым | `scripts/watchdog.sh` + таймер: панель, порт, сквозной туннель, Telegram |
| Бэкап, который переживёт потерю VPS | `backup-db.sh --offsite`: `sqlite3 .backup`, `age`, `rclone`, ротация |
| Не гадать, что сломано | 25 bats-тестов на фикстурах и фальшивой панели обеих схем API |
| Утечка мимо туннеля | `references/ipv6.md`, `verify_vless.py --family 6`, IPv6 в аудите |
| Провайдер душит TCP/443 | `references/hysteria2.md` + `install_singbox_hysteria2.sh` |

## Что нового в 3.0

Порт с Qwen Code на модель-агностичный формат и исправление ошибок, которые ломали
установку:

| Было (v2.0) | Стало (v3.0) |
|---|---|
| Гайд `vpn-<nick>-guide.md` с IP, логином и паролем панели | Никаких файлов с секретами; секрет показывается один раз в чат |
| `echo "Save this password: $PASS"` в лог | Пароль не печатается в журнал и не попадает в историю |
| `x25519` вызывался дважды → приватный и публичный ключи из разных пар | Один вызов, пара проверяется `x25519 -i` |
| Сканер SNI работал «в стол», в конфиг шёл `google.com:443` | `references/reality-sni.md`: выбор цели с проверкой TLS 1.3 + h2 |
| `sed 's/^PermitRootLogin.*/.../'` на закомментированной строке молча ничего не делал | Drop-in `sshd_config.d/99-hardening.conf` + `sshd -t` + автооткат |
| ICMP гасился правкой `ufw/before.rules`, терялось при `ufw reset` | `sysctl net.ipv4.icmp_echo_ignore_all=1` |
| «Проверка» = `x-ui status` и `ss -tlnp` | `scripts/verify_vless.py`: сквозной тест, exit IP |
| Порт панели читался из `/etc/x-ui/x-ui.sh` | Из БД `settings` (рабочая БД — `/etc/x-ui/x-ui.db`) |
| Нет бэкапа и отката перед рискованными шагами | Бэкап в `/root/vpn-backup-<дата>/`, таймер автоотката |
| `QWEN.md`, `Allowed Tools`, `~/.qwen/skills` | Hermes-формат `SKILL.md`, установка в `~/.hermes/skills/...` |
| Нет защиты от утечки секретов в репозиторий | `scripts/check_no_secrets.sh` + CI на каждый push |

---

## Установка

```bash
git clone https://github.com/GilGameshx1/3x-ui-skill.git
cd 3x-ui-skill
./install.sh                       # → ~/.hermes/skills/infrastructure/3x-ui-vpn
```

Другой каталог (Claude Code, Qwen, что угодно):

```bash
./install.sh --dir ~/.claude/skills/3x-ui-vpn
```

Или вручную: скопировать репозиторий в каталог навыков агента — структура
(`SKILL.md` + `references/` + `scripts/`) одинаковая у Hermes, Claude Code и Qwen.

## Использование

Скажите агенту обычными словами — навык подхватится по описанию:

- «Настрой VPN на новом VPS, вот IP»
- «Проверь, всё ли в порядке на сервере с VPN»
- «Сменился IP, перенастрой клиентов»
- «Добавь пользователя в панель и дай ссылку»

Требования: Debian 10+ / Ubuntu 20.04+, root на первом шаге, SSH-ключ на клиенте.
Домен нужен только для варианта VLESS TLS.

## Что внутри

```
SKILL.md                            пять режимов, правила, грабли
references/reality-sni.md           выбор SNI: требования, проверка, антипаттерны
references/reality-link-format.md   из чего собирается vless://
references/vless-tls.md             вариант с доменом и сертификатом
references/subscription.md          подписка: настройки, TLS, клиенты, грабли
references/watchdog.md              сторож: что проверяет, установка, алерты
references/backup-offsite.md        бэкап наружу (rclone + age), восстановление
references/ip-migration.md          переезд на новый IP: маршрут, NAT, docker, LE
references/ipv6.md                  IPv6: утечки и v6-inbound
references/hysteria2.md             второй транспорт на UDP
references/fallback-nginx.md        страница-заглушка для TLS-варианта
scripts/server_audit.sh             read-only аудит сервера (включая IPv6)
scripts/state_check.sh              состояние по факту: PASS/WARN/FAIL
scripts/verify_vless.py             сквозная проверка через локальный socks
scripts/add_client.sh               клиент с лимитами через API панели
scripts/sub_setup.sh                подписка и subId
scripts/watchdog.sh                 сторож + Telegram
scripts/backup-db.sh                бэкап БД x-ui (age, rclone)
scripts/restore-db.sh               восстановление .db/.gz/.age
scripts/install_singbox_hysteria2.sh  Hysteria2 рядом с Reality
scripts/check_no_secrets.sh         страж репозитория
scripts/lib/xui.py                  БД, API панели, ссылки, подписка
systemd/                            таймеры бэкапа и сторожа
tests/                              bats-тесты (фикстуры + фальшивая панель)
```

## Пять режимов

1. **Развёртывание** — свежий VPS: пользователь + ключ, UFW с автооткатом, sysctl,
   3x-ui на `127.0.0.1`, Reality с проверенным SNI, сквозной тест, замок SSH последним.
2. **Аудит и ремонт** — `server_audit.sh`, сверка «заявлено / фактически», типовые
   поломки (docker NAT, BBR, ufw-юнит, flow, сертификаты).
3. **Смена IP** — маршрут и `src`, SNAT для контейнеров, пересоздание MTProto,
   сертификат на новый адрес, проверка, чистка старого адреса.
4. **Клиенты и подписка** — лимиты по трафику/сроку/IP, `subId`, автообновление ссылок.
5. **Эксплуатация** — `state_check.sh`, сторож с алертом, шифрованный бэкап вне сервера.

## Клиенты

| Платформа | Клиенты |
|---|---|
| Android | Hiddify, v2rayNG, NekoBox |
| iOS | Hiddify, Streisand, V2Box (Shadowrocket — платный) |
| Windows / macOS / Linux | Hiddify, NekoRay, v2rayN, FoXray |

Для `flow=xtls-rprx-vision` нужен свежий клиент; старый подключится только после
обновления.

## Проверка перед публикацией

```bash
bash scripts/check_no_secrets.sh   # секреты: IP, ссылки, ключи, пароли
shellcheck -x -S warning scripts/*.sh install.sh
bats tests/                        # 25 тестов на фикстурах, без VPN
```

Всё это же гоняется в CI (`.github/workflows/ci.yml`) на каждый push и PR.

## Лицензия

MIT. Исходная версия — [GilGameshx1/3x-ui-skill](https://github.com/GilGameshx1/3x-ui-skill)
(Qwen Code, v2.0), адаптирована из навыка
[AndyShaman](https://github.com/AndyShaman/3x-ui-skill) для Claude Code.

## Ссылки

- [3x-ui](https://github.com/mhsanaei/3x-ui)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [Hiddify](https://github.com/hiddify/hiddify-app)
- [RealiTLScanner](https://github.com/XTLS/RealiTLScanner)
