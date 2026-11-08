# Сторож: узнавать о поломке раньше пользователя

Таймер раз в 5 минут проверяет панель, порт и сквозной проход трафика, при
поломке пишет в Telegram. Без этого о том, что VPN лёг, сообщает пользователь —
иногда через сутки.

## Что проверяется

1. `systemctl is-active x-ui`.
2. Слушается ли порт включённого входящего (`ss -ltn`).
3. Отвечает ли панель по HTTP на `127.0.0.1:<webPort><webBasePath>`.
4. Если в конфиге заданы креды клиента — `verify_vless.py`: локальный xray
   поднимает socks, идёт через туннель на `127.0.0.1:<port>` и сверяет exit IP.
   Это единственная проверка, которая ловит «порт открыт, а трафик не ходит».

Алерт отправляется не чаще `ALERT_EVERY_MIN` (30 минут), при восстановлении —
одно сообщение «снова работает». Состояние — в `/var/lib/3x-ui-watchdog/state`.

## Установка

```bash
# 1. Скрипты в стабильные пути
install -m 755 scripts/watchdog.sh   /usr/local/bin/3x-ui-watchdog
install -m 755 scripts/verify_vless.py /usr/local/bin/3x-ui-verify
# watchdog.sh ищет verify_vless.py рядом с собой — положить оба в один каталог:
install -m 755 scripts/watchdog.sh scripts/verify_vless.py /usr/local/bin/

# 2. Настройки (права 600: внутри токен бота)
cat >/etc/3x-ui-watchdog.env <<'EOF'
CHECK_PORT=8443
CHECK_UUID=<UUID>
CHECK_PBK=<PUBLIC_KEY>
CHECK_SNI=<SNI>
CHECK_SID=<SHORT_ID>
CHECK_FLOW=xtls-rprx-vision
EXPECT_IP=<SERVER_IP>
TELEGRAM_BOT_TOKEN=<BOT_TOKEN>
TELEGRAM_CHAT_ID=<CHAT_ID>
EOF
chmod 600 /etc/3x-ui-watchdog.env

# 3. Юниты и таймер
install -m 644 systemd/3xui-watchdog.service systemd/3xui-watchdog.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now 3xui-watchdog.timer
systemctl start 3xui-watchdog.service   # первый прогон сразу
journalctl -u 3xui-watchdog -n 30 --no-pager
```

Бот: `@BotFather` → `/newbot` → токен. `CHAT_ID` — `getUpdates` после сообщения
боту, либо `@userinfobot`.

## Проверка, что сторож не врёт

Проверять нужно не «алерт пришёл», а оба направления:

```bash
systemctl start 3xui-watchdog.service; echo $?          # 0 = PASS
systemctl stop x-ui && systemctl start 3xui-watchdog.service   # должен упасть и написать
systemctl start x-ui && systemctl start 3xui-watchdog.service  # снова 0, «снова работает»
```

Если сторож молчит при остановленной панели — смотреть `journalctl`, обычно пустой
`TELEGRAM_*` или нет прав на `/var/lib/3x-ui-watchdog`.

## Грабли

- **Проверка через свой же туннель с самого сервера** — единственный вариант без
  внешней точки. Она не поймает блокировку провайдером снаружи; для этого раз в
  сутки полезен внешний чекер (check-host.net, см. SKILL.md).
- **Креды клиента в env — это секрет.** Файл 600, в git не попадает, при смене
  клиента обновить `CHECK_UUID`.
- **Таймер не «каждые 5 минут от старта», а `OnUnitActiveSec`** — иначе при
  зависшем прогоне проверки накладываются друг на друга.
- **Алерт-шторм.** Без `ALERT_EVERY_MIN` и файла состояния один лежащий VPN даёт
  288 сообщений в сутки.
- **`set -u` и пустой массив проблем.** В bash 4.4+ `"${problems[@]}"` при пустом
  массиве безопасен, но при `set -u` в старом bash — нет; поэтому цикл по проблемам
  сделан через printf с проверкой длины.
