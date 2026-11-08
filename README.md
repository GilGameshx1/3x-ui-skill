# 3x-ui-vpn

Навык для ИИ-агента, который доводит VPS до рабочего VPN-сервера и поддерживает его
в живом состоянии: разворачивает с нуля, проверяет и чинит уже работающий сервер,
выдаёт клиентов, следит за падением и делает бэкапы.

Работает с любым агентом, который читает `SKILL.md` и умеет вызывать shell:
Hermes Agent, Claude Code, DeepSeek, Qwen и другие. Подробная история изменений —
в [CHANGELOG.md](CHANGELOG.md).

> В файлах навыка нет и не будет реальных IP, паролей, ключей или готовых ссылок —
> только плейсхолдеры вида `<SERVER_IP>`, `<UUID>`, `<PBK>`.

## Возможности

- **Развёртывание с нуля** — укрепление ОС (UFW, fail2ban, sysctl, BBR), установка
  3x-ui, VLESS Reality или TLS, сквозная проверка на живом трафике.
- **Аудит и ремонт** — read-only аудит сервера, сверка «заявлено / фактически»,
  типовые поломки: docker NAT, BBR, ufw, flow, сертификаты.
- **Смена IP** — маршрут и `src`, SNAT для контейнеров, сертификат на новый адрес,
  сквозная проверка, чистка старого адреса.
- **Клиенты и подписка** — лимиты по трафику, сроку и числу IP, автообновление ссылок.
- **Эксплуатация** — состояние по факту, сторож с алертом в Telegram, шифрованный
  бэкап вне сервера.
- **IPv6 и второй транспорт** — контроль утечек IPv6, Hysteria2 (UDP) для сетей,
  где режут TCP/443.
- **27 bats-тестов** — на фикстурах и фальшивой панели, без поднятия VPN.

## Установка

```bash
git clone https://github.com/GilGameshx1/3x-ui-skill.git
cd 3x-ui-skill
./install.sh                       # → ~/.hermes/skills/infrastructure/3x-ui-vpn
```

Другой каталог — для Claude Code, Qwen или любого агента:

```bash
./install.sh --dir ~/.claude/skills/3x-ui-vpn
```

Можно и вручную: скопировать репозиторий в каталог навыков агента. Структура
(`SKILL.md` + `references/` + `scripts/`) одинаковая у Hermes, Claude Code и Qwen.

## Использование

Скажите агенту обычными словами — навык подхватится по описанию:

- «Настрой VPN на новом VPS, вот IP»
- «Проверь, всё ли в порядке на сервере с VPN»
- «Сменился IP, перенастрой клиентов»
- «Добавь пользователя в панель и дай ссылку»

Требования: Debian 10+ / Ubuntu 20.04+, root на первом шаге, SSH-ключ на клиенте.
Домен нужен только для варианта VLESS TLS.

## Структура

```
SKILL.md                              пять режимов, правила, грабли
references/reality-sni.md             выбор SNI: требования, проверка, антипаттерны
references/reality-link-format.md     из чего собирается vless://
references/vless-tls.md               вариант с доменом и сертификатом
references/subscription.md            подписка: настройки, TLS, клиенты, грабли
references/watchdog.md                сторож: что проверяет, установка, алерты
references/backup-offsite.md          бэкап наружу (rclone + age), восстановление
references/ip-migration.md            переезд на новый IP: маршрут, NAT, docker, LE
references/ipv6.md                    IPv6: утечки и v6-inbound
references/hysteria2.md               второй транспорт на UDP
references/fallback-nginx.md          страница-заглушка для TLS-варианта
references/client-db-operations.md    клиенты через БД, когда нет пароля панели
references/hardening-audit.md         укрепление и аудит
references/xray-3xui-operations.md    повседневные операции с xray/3x-ui
scripts/server_audit.sh               read-only аудит сервера (включая IPv6)
scripts/state_check.sh                состояние по факту: PASS/WARN/FAIL
scripts/verify_vless.py               сквозная проверка через локальный socks
scripts/add_client.sh                 клиент с лимитами через API панели
scripts/sub_setup.sh                  подписка и subId
scripts/watchdog.sh                   сторож + Telegram
scripts/backup-db.sh                  бэкап БД x-ui (age, rclone)
scripts/restore-db.sh                 восстановление .db/.gz/.age
scripts/install_singbox_hysteria2.sh  Hysteria2 рядом с Reality
scripts/rollback.sh                   откат установки
scripts/check_no_secrets.sh           страж репозитория
scripts/lib/xui.py                    БД, API панели, ссылки, подписка
systemd/                              таймеры бэкапа и сторожа
tests/                                bats-тесты (фикстуры + фальшивая панель)
```

## Режимы работы

1. **Развёртывание** — свежий VPS: пользователь + ключ, UFW с автооткатом, sysctl,
   3x-ui на `127.0.0.1`, Reality с проверенным SNI, сквозной тест, замок SSH последним.
2. **Аудит и ремонт** — `server_audit.sh`, сверка «заявлено / фактически», типовые
   поломки (docker NAT, BBR, ufw-юнит, flow, сертификаты).
3. **Смена IP** — маршрут и `src`, SNAT для контейнеров, пересоздание MTProto,
   сертификат на новый адрес, проверка, чистка старого адреса.
4. **Клиенты и подписка** — лимиты по трафику, сроку и числу IP, `subId`,
   автообновление ссылок.
5. **Эксплуатация** — `state_check.sh`, сторож с алертом, шифрованный бэкап
   вне сервера.

## Клиенты

| Платформа           | Клиенты                                              |
|---------------------|------------------------------------------------------|
| Android             | Hiddify, v2rayNG, NekoBox                            |
| iOS                 | Hiddify, Streisand, V2Box (Shadowrocket — платный)   |
| Windows / macOS / Linux | Hiddify, NekoRay, v2rayN, FoXray                  |

Для `flow=xtls-rprx-vision` нужен свежий клиент; старый подключится только после
обновления.

## Проверка перед публикацией

```bash
bash scripts/check_no_secrets.sh   # секреты: IP, ссылки, ключи, пароли
shellcheck -x -S warning scripts/*.sh install.sh
bats tests/                        # 27 тестов на фикстурах, без VPN
```

Всё то же самое гоняется в CI (`.github/workflows/ci.yml`) на каждый push и PR.

## Лицензия

MIT. Исходная версия — [AndyShaman/3x-ui-skill](https://github.com/AndyShaman/3x-ui-skill)
для Claude Code, адаптирована в [GilGameshx1/3x-ui-skill](https://github.com/GilGameshx1/3x-ui-skill).

## Ссылки

- [3x-ui](https://github.com/mhsanaei/3x-ui)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [Hiddify](https://github.com/hiddify/hiddify-app)
- [RealiTLScanner](https://github.com/XTLS/RealiTLScanner)
