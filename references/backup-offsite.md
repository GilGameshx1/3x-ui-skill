# Бэкап БД вне сервера: rclone + age

Бэкап в `/root` защищает от «сломал конфиг», но не от потери VPS: диск умирает
вместе с копиями. Минимум — зашифрованная копия в чужое хранилище.

## Что делает скрипт

```bash
scripts/backup-db.sh --offsite
```

1. `sqlite3 .backup` — согласованная копия живой БД (в WAL-режиме `cp` даёт битый
   файл).
2. `pragma integrity_check` уже на копии — проверяется то, что реально уедет.
3. Сжатие `gzip -9`; если задан `AGE_RECIPIENT` — шифрование `age`.
4. `rclone copy` в удалённое хранилище и проверка по факту: имя файла должно
   появиться в `rclone lsf`.
5. Ротация локально и на удалённой стороне (`--keep`, по умолчанию 10).

Имена: `x-ui-YYYYmmdd-HHMMSS.db.gz` или `.db.age`. Права 600.

## Настройка за один раз

```bash
# 1. rclone и age
apt install -y rclone age

# 2. Удалённое хранилище (пример: S3-совместимое; для B2/gdrive/dropbox — свои
#    вопросы интерактивно)
rclone config create backup s3 provider=Other \
  access_key_id=<ACCESS_KEY> secret_access_key=<SECRET_KEY> \
  endpoint=<ENDPOINT> region=<REGION>
rclone lsd backup:                 # remote виден

# 3. Ключ age. Приватный ключ НЕ должен лежать только на этом сервере:
#    иначе потеря VPS = потеря расшифровки. Скопировать в менеджер паролей.
age-keygen -o /root/age.key
chmod 600 /root/age.key
age-keygen -y /root/age.key        # это публичный ключ (recipient), не секрет

# 4. Настройки выгрузки
cat >/etc/3x-ui-backup.env <<'EOF'
RCLONE_REMOTE=backup:vpn-backups
AGE_RECIPIENT=<PUBLIC_KEY_AGE>
EOF
chmod 600 /etc/3x-ui-backup.env

# 5. Скрипт и таймер
install -m 755 scripts/backup-db.sh /usr/local/bin/3x-ui-backup
install -m 644 systemd/3x-ui-backup.service systemd/3x-ui-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now 3x-ui-backup.timer
systemctl start 3x-ui-backup.service
journalctl -u 3x-ui-backup -n 20 --no-pager
```

Первый прогон обязательно проверить руками: `rclone lsf backup:vpn-backups`
должен показать свежий файл, размер — не нулевой.

## Восстановление (проверять заранее, а не в момент аварии)

```bash
# 1. Забрать копию
rclone copy backup:vpn-backups/x-ui-<STAMP>.db.age /root/

# 2. Расшифровать и распаковать
age -d -i /root/age.key /root/x-ui-<STAMP>.db.age > /root/x-ui.db
sqlite3 /root/x-ui.db "pragma integrity_check;"      # ok

# 3. Подменить БД (панель остановлена!)
x-ui stop
cp /etc/x-ui/x-ui.db /root/x-ui.db.broken.$(date +%F)   # текущую — в сторону
cp /root/x-ui.db /etc/x-ui/x-ui.db
x-ui start

# 4. Проверить, что вернулось именно то
scripts/state_check.sh --quick
scripts/verify_vless.py --ip <SERVER_IP> --port <PORT> --uuid <UUID> \
        --pbk <PBK> --sni <SNI> --sid <SID> --flow xtls-rprx-vision
```

Скрипт `restore-db.sh` понимает `.gz`, `.age` и голый `.db` — если удобнее, делать
через него.

## Грабли

- **`cp` вместо `.backup`.** Панель пишет в WAL; `cp` без `-wal`/`-shm` даёт БД,
  которая «восстановилась», но без последних клиентов.
- **Ключ age на том же диске.** Шифрование не защищает от потери сервера, если
  расшифровывать нечем. Ключ — в менеджер паролей и вторая копия вне VPS.
- **`rclone copy` без проверки.** Команда может вернуть 0 при пустом remote
  (неверный путь). Поэтому `lsf | grep` после копирования — обязателен.
- **Квота хранилища.** Ротация на удалённой стороне удаляет старые `x-ui-*.db.*`;
  если квота кончилась, `rclone` падает, а локальный бэкап выглядит здоровым.
  Сторож проверяет свежесть локальной копии (`state_check.sh`), но не квоту remote.
- **Бэкап БД не равен бэкапу сервера.** Сертификаты, `/etc/network/interfaces`,
  конфиги контейнеров и `/root/age.key` в БД не входят — их кладут в тот же
  архив отдельным шагом, если сервер поднимается с нуля.
