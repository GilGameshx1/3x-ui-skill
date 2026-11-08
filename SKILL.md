---
name: 3x-ui-vpn
description: VPN на 3x-ui — развернуть, проверить, переехать, усилить.
version: 3.1.0
author: GilGameshx1 (port: Hermes Agent / DeepSeek)
license: MIT
metadata:
  hermes:
    tags: [vpn, xray, 3x-ui, vless, reality, vps, hardening, migration]
    related_skills: []
---

# 3x-ui VPN на VPS

Один навык на три задачи: развернуть VPN с нуля, проверить/починить живой сервер,
переехать на новый IP. Обслуживает Xray/3x-ui (VLESS Reality или VLESS TLS),
AmneziaWG и MTProto-прокси, если они есть.

Отвечай по-русски. Команды и вывод — англоязычные, объяснения — русские.

Навык не зависит от конкретной модели: он написан как последовательность
проверяемых шагов и shell-команд, а не как «вызовы инструментов». Годится для
DeepSeek, Qwen, Claude, GPT — у любого агента с доступом к терминалу.

## Когда использовать

- «Настрой VPN на новом VPS», «поставь 3x-ui / VLESS / Reality».
- «Посмотри, всё ли в порядке на сервере», «VPN перестал подключаться».
- «Сменился IP, надо перенастроить» / «переезжаем на другой сервер».
- «Усиль сервер»: SSH, UFW, fail2ban, BBR, сертификаты.
- «Выдай ссылку на подключение» / «добавь пользователя в панель».
- «Сделай подписку, чтобы ссылки обновлялись сами».
- «Что на сервере реально сделано» / «сервер жив, но VPN не работает».
- «Настрой бэкапы и чтобы о падении узнавали сразу».
- «Провайдер душит TCP/443 — дай второй транспорт».

## Железные правила

1. **«Готово» — только после сквозной проверки.** Правка конфига ничего не доказывает.
   Подними локальный xray с socks-inbound до сервера и проверь exit IP
   (`scripts/verify_vless.py`). Не видел PASS и нужный IP — не отчитывайся «работает».
2. **Автооткат перед рискованным изменением** сети, файрвола или SSH:
   `systemd-run --on-active=360 --unit=netguard /root/revert.sh`, после успешной
   проверки — `systemctl stop netguard.timer`. Это единственная страховка, если доступ
   отвалится; без неё не трогай `sshd` и `ufw`.
3. **Не верь гайду, сгенерированному предыдущим ИИ.** Проверяй фактом: пароль панели —
   POST на `/login`, BBR — `sysctl net.ipv4.tcp_congestion_control`, ICMP —
   `sysctl net.ipv4.icmp_echo_ignore_all`, файрвол — `ufw status`, вход по ключу —
   реальный `ssh -o BatchMode=yes`. В чужом гайде бывают неверный пароль, выдуманный
   public key и заявленное, но не сделанное укрепление.
4. **Секреты не сохраняются** — см. раздел «Политика секретов». Ни IP, ни паролей,
   ни UUID, ни ключей, ни готовых `vless://` в файлах навыка и репозитория.
5. **Публичный ключ Reality выводи из приватного:** `xray x25519 -i <privkey>`.
   Значение из БД, гайда или «сгенерированное отдельным запуском» — не истина:
   два отдельных вызова `x25519` дают две разные пары.
6. **Бэкап до изменений:** БД x-ui, `/etc/network/interfaces`, `sysctl.d`, конфиг AWG,
   скрипты запуска контейнеров — в `/root/vpn-backup-<дата>/`. Путь указать в отчёте.

## Политика секретов

Что считается секретом: IP и hostname сервера, логин/пароль панели, UUID клиентов,
приватные и публичные ключи Reality, `shortId`, `vless://`-ссылки, `tg://`-ссылки,
секрет 2FA, ключи SSH.

Правила:

- В файлах навыка и в репозитории — **только плейсхолдеры**: `<SERVER_IP>`, `<PORT>`,
  `<UUID>`, `<PBK>`, `<SID>`, `<SNI>`, `<USER>`, `<PASS>`. Примеры без реальных значений.
- Сгенерированный секрет показывается **один раз в чат** и дальше живёт у пользователя
  (менеджер паролей / приложение). На сервере — только там, где его требует софт
  (БД x-ui, `authorized_keys`).
- Запрещено: `echo "пароль: $PASS"` в лог, запись гайда с кредами, `>> ~/.bash_history`,
  пароль в аргументах команды (виден в `ps` и истории) — использовать stdin:
  `x-ui setting -password` (спросит) или `read -rsp`.
- Ссылку клиенту отдавай в чат или через подписку; файл на диске — только если
  пользователь сам попросил, и тогда `chmod 600` + предупреждение.
- Перед коммитом/публикацией: `bash scripts/check_no_secrets.sh` — падает на IPv4,
  `vless://`, `BEGIN ... PRIVATE KEY`, `password=`. Это же в CI.
- `.gitignore` закрывает `*guide*.md`, `*.db`, `*.key`, `*.pem`, `backup*/`.

Если пользователь сам прислал IP и пароль в чат — это его данные, работать можно,
но в файлы навыка они не попадают ни при каких условиях.

## Режим A. Свежий VPS

### A0. Вводные

Спросить: IP, есть ли уже SSH-ключ, желаемое имя пользователя (3–16 символов,
нижний регистр), ник для `~/.ssh/config`, есть ли домен (для Reality не нужен).

Пароль root просить **только** если ключа нет, и сразу предупредить: после настройки
вход по паролю выключается. Пароль не эхоить и не писать в файлы. Проверить ОС
(`/etc/debian_version`, Debian 10+/Ubuntu 20.04+), что это свежая машина, и что
провайдер не режет 443.

### A1. Гигиена сервера

```bash
apt update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y
apt install -y curl wget unzip sqlite3 chrony ufw fail2ban ca-certificates
timedatectl set-ntp true
```

Пользователь + ключ (ключ генерируется на клиенте, приватный не покидает клиент):

```bash
adduser --disabled-password --gecos "" <USER>
usermod -aG sudo <USER>
install -d -m 700 -o <USER> -g <USER> /home/<USER>/.ssh
# публичный ключ — через ssh-copy-id, не через echo в чат
ssh-copy-id -i ~/.ssh/<NICK>_key.pub <USER>@<SERVER_IP>
```

**Стоп-гейт:** `ssh -i ~/.ssh/<NICK>_key -o BatchMode=yes <USER>@<SERVER_IP> 'sudo -n true'`
должен пройти. Не прошёл — не идти дальше, вход по паролю ещё работает, чинить сейчас.

UFW — с автооткатом (правило 2):

```bash
systemd-run --on-active=420 --unit=ufw-revert sh -c 'ufw --force disable'
ufw default deny incoming; ufw default allow outgoing
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw --force enable; ufw status verbose
```

Панель наружу **не открывать** — только `127.0.0.1` и SSH-туннель. Проверить, что
новая SSH-сессия открывается, и снять таймер: `systemctl stop ufw-revert.timer`.

Ядро — отдельным файлом, не в `/etc/sysctl.conf`:

```bash
cat >/etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system
```

ICMP-стелс — через sysctl (`net.ipv4.icmp_echo_ignore_all = 1`), а не правкой
`/etc/ufw/before.rules`: `ufw reset`/`reload` возвращает свои правила и правка молча
теряется.

### A2. Панель 3x-ui

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

Установщик печатает логин/пароль один раз. Не пересказывать их в отчёт и не писать
в файл. Сразу:

```bash
x-ui setting -port <PANEL_PORT> -webBasePath /<RANDOM_PATH>
x-ui restart
```

Порт панели и базовый путь читаются из БД, а не из `/etc/x-ui/x-ui.sh` (там бывают
устаревшие значения):

```bash
sqlite3 /etc/x-ui/x-ui.db "select key,value from settings where key in ('webPort','webBasePath');"
```

Рабочая БД — `/etc/x-ui/x-ui.db`. Пустой `/usr/local/x-ui/x-ui.db` — приманка.

### A3. Reality

Готовый inbound, порт 443 (или 8443, если 443 занят MTProto), `flow=xtls-rprx-vision`.

Выбор SNI — `references/reality-sni.md`: цель должна отвечать TLS 1.3 + h2 с сервера,
быть чужой и стабильной. Сканер подсети — только как подсказка, его вывод надо
проверить `openssl s_client` и подставить в `dest`/`serverNames`.

Ключи — **один** вызов, пара из одного запуска:

```bash
XRAY=$(ls /usr/local/x-ui/bin/xray-linux-*)
read -r PRIV PUB <<<"$($XRAY x25519 | awk '/[Pp]rivate/{p=$NF} /[Pp]ublic|[Pp]assword/{q=$NF} END{print p, q}')"
```

В новых версиях Xray публичный ключ в выводе называется `Password` — парсить оба
варианта. Проверка пары:

```bash
[ "$($XRAY x25519 -i "$PRIV" | awk '{print $NF}')" = "$PUB" ] && echo PAIR_OK
```

Inbound создаётся через API панели (`/panel/api/inbounds/add`) или вставкой в БД;
`settings` и `streamSettings` — JSON-строки внутри JSON. `listen` оставить пустым
(слушать все адреса), `decryption: "none"`.

### A4. Ссылка и клиент

Формат — `references/reality-link-format.md`. Ссылку отдать в чат; в файл — только
по просьбе. Клиенты: Hiddify (универсальный), v2rayNG/NekoBox (Android),
Streisand/V2Box (iOS), NekoRay/v2rayN (десктоп). `flow=xtls-rprx-vision` требует
свежий клиент; старый молча не подключится — предупредить.

### A5. Проверка (обязательно)

```bash
python3 scripts/verify_vless.py --ip <SERVER_IP> --port <PORT> --uuid <UUID> \
        --pbk <PBK> --sni <SNI> --sid <SID> --flow xtls-rprx-vision --expect <SERVER_IP>
```

PASS = соединение установлено и exit IP равен адресу сервера. Дополнительно — что
порт виден снаружи (API check-host.net, см. «Грабли»): curl с самого сервера на свой
IP ничего не доказывает.

### A6. Замок SSH — последним шагом

Только после A5. Через drop-in, а не `sed` по `sshd_config` (строки там часто
закомментированы, `sed 's/^PermitRootLogin.*/.../'` тихо ничего не меняет):

```bash
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
sshd -t && systemctl reload ssh
```

`sshd -t` до рестарта, автооткат (правило 2) — до правки, проверка новой сессией —
после. fail2ban включить здесь же, `ignoreip` — актуальный админский IP.

## Режим B. Аудит и ремонт живого сервера

1. `bash scripts/server_audit.sh` — ОС, адреса, маршрут, порты, юниты, docker, ufw,
   `sshd -T`, sysctl, серты, диск, обновления. Скрипт только читает.
2. Сверить заявленное с фактическим (правило 3) и составить таблицу «заявлено /
   на самом деле / чем проверено».
3. Типовые поломки — раздел «Грабли».
4. Любая правка → проверка `verify_vless.py` → отчёт.

## Режим C. Смена IP

Порядок и подводные камни — `references/ip-migration.md`. Коротко: новый IP уже на
интерфейсе и маршрутизируется → `src` в default route → SNAT для docker → пересоздать
контейнеры, которые узнают внешний IP при старте → сертификат на новый адрес →
сквозная проверка → снять автооткат → почистить старый IP из конфигов.

## Режим D. Клиенты, лимиты, подписка

```bash
# Клиент с лимитами; печатает vless:// и URL подписки ОДИН раз в чат
scripts/add_client.sh --inbound 1 --email ivan --expiry-days 30 --quota-gb 100 --limit-ip 2
scripts/add_client.sh --inbound VLESS-443 --email ivan --update --quota-gb 200
scripts/add_client.sh --inbound 1 --email ivan --dry-run --json    # план без изменений

# Подписка: включить, выдать subId старым клиентам, проверить запросом
scripts/sub_setup.sh
scripts/sub_setup.sh --assign-subids
```

Клиента создаёт **API панели**, а не SQL: в новых версиях клиенты живут в
нормализованных таблицах `clients` / `client_inbounds`, плюс строка в
`client_traffics`. Прямая вставка в `settings` JSON их не создаёт и статистику не
заводит. Скрипт после создания перечитывает карточку клиента из панели — «API
ответил 200» не считается доказательством.

Два подводных камня в цифрах: `totalGB` в 3x-ui хранится **в байтах** (имя врёт),
`expiryTime` — epoch **в миллисекундах**, `0` = без ограничения.

Подписка: `subEnable/subPort/subPath/subURI`, URL = `<subURI или схема://хост:порт+путь><subId>`.
Детали, TLS и клиенты — `references/subscription.md`.

## Режим E. Эксплуатация: состояние, сторож, бэкапы

```bash
scripts/state_check.sh                  # PASS/WARN/FAIL по факту, ничего не меняет
scripts/state_check.sh --json --strict  # для мониторинга: код 1 при FAIL
scripts/backup-db.sh --offsite          # копия + age + rclone наружу
scripts/watchdog.sh --verbose           # один прогон сторожа
```

`state_check.sh` — это ответ на «что реально сделано»: панель, порты, пара ключей
Reality, включённость подписки, SSH, UFW, sysctl, сертификаты, свежесть бэкапа,
таймеры, IPv6, диск, `xray -test`. Каждая строка — проверка, а не пересказ гайда.

Сторож и бэкап ставятся таймерами (`systemd/`): 5 минут — проверка туннеля с
алертом в Telegram, ежедневно — зашифрованный бэкап вне сервера.
`references/watchdog.md`, `references/backup-offsite.md`.

## IPv6 и второй транспорт

- IPv6 включён у хостера, а туннель только IPv4 → трафик уходит мимо. Проверять
  `ip -6 addr`, `curl -6 https://ipv6.icanhazip.com`, `verify_vless.py --family 6`;
  сценарии «выключить» и «сделать v6-inbound» — `references/ipv6.md`.
- Провайдер душит TCP/443 → Hysteria2 (UDP) рядом, не вместо Reality:
  `scripts/install_singbox_hysteria2.sh --domain <DOMAIN> --cert-mode acme`,
  детали — `references/hysteria2.md`.

## Грабли

- **Docker MASQUERADE берёт первый IPv4 на интерфейсе**, а не `src` из маршрута:
  после смены маршрута контейнеры продолжают выходить со старого IP. Лечится SNAT
  (`references/ip-migration.md`).
- **Docker при старте вставляет свои nat-правила в начало POSTROUTING** — свой SNAT
  вешать через drop-in `docker.service` (`ExecStartPost`), иначе после рестарта он
  окажется после MASQUERADE и молча не сработает.
- **Контейнер, определяющий внешний IP при старте** (официальный
  `telegrammessenger/proxy` делает `curl .../myIp` в `run.sh`), надо пересоздавать
  после смены IP. Смотри `docker exec <c> cat /run.sh`.
- **Let's Encrypt не выдаёт серт на IP в профиле по умолчанию:** нужен
  `acme.sh --issue -d <IP> --standalone --cert-profile shortlived`. IP-серты живут
  ~6 дней, продление по ARI; без `--reloadcmd "systemctl restart x-ui"` панель
  останется со старым.
- **`modprobe tcp_bbr` → «Module bbr not found»** при существующем `tcp_bbr.ko`:
  устаревший `modules.dep` → `depmod -a $(uname -r)`, затем modprobe.
- **`ufw --force reset && ufw enable` оставляет `ufw.service` в inactive (dead)** при
  живых правилах. Проверяй `ufw status`, а не `is-active`; `systemctl start ufw`
  приводит юнит в норму.
- **Порты, опубликованные docker (`-p 443:443`), обходят UFW** — политика INPUT на них
  не действует; закрывать через `-p 127.0.0.1:` или цепочку DOCKER-USER.
- **AmneziaWG:** приватный ключ клиента есть только на устройстве, конфиг на сервере
  пересоздать нельзя — инструктируй менять `Endpoint = <IP>:<PORT>` в приложении.
- **Xray предупреждает «VLESS (with no Flow) is deprecated»** — предлагай
  `xtls-rprx-vision`, но не меняй молча: потребуется обновить ссылку.
- **Клиент без `flow` в 26.x** — при тесте получишь FAIL «соединение не установлено».
  Перепроверь `--flow ''` прежде чем искать проблему в ключах и портах; у клиента с
  `subId` подписка отдаст новую ссылку сама.
- **2FA в 3x-ui — это TOTP, а не Telegram-код:** `twoFactorEnable=1`,
  `twoFactorToken=<base32>` в `settings`. Проверять реально: без кода и с неверным
  кодом вход отклоняется, с верным — проходит. Аварийный выход —
  `x-ui setting -resetTwoFactor`. Секрет 2FA в файлы не писать: только `otpauth://`
  в чат.
- **Внешняя проверка порта без своего браузера — API check-host.net.** Запрос →
  `request_id`, результат через ~12 с; `null` вместо узлов — рано, подожди ещё.
- **`xray x25519 -i <priv>` печатает три строки:** `PrivateKey`, `Password`,
  `Hash32`. Публичный ключ — `Password`, а не последняя строка вывода: `awk '{print
  $NF}'` вернёт `Hash32` и «проверка ключей» провалится на исправной паре.
- **Сохранённый `publicKey` может не совпадать с `privateKey` строкой, оставаясь
  тем же ключом.** Частый случай — base64 с паддингом (`=` в конце, 44 символа)
  вместо base64url без него (43): байты те же, но xray-клиент такую ссылку не
  принимает. Прежде чем перевыпускать пару, сравнить **декодированные байты**:
  совпали — это кодировка, лечится нормализацией значения, клиентам достаточно
  обновить ссылку. Не совпали — ключи действительно из разных пар (два вызова
  `x25519`), тогда перевыпуск пары и рассылка новых ссылок.
- **Панель может слушать `*:<port>`, а не `127.0.0.1`.** `ufw` это прикрывает, но
  проверять надо `ss -ltn`, а не статус ufw: при смене файрвола панель окажется
  снаружи. `state_check.sh` ловит это как `panel.exposure`.
- **`cp x-ui.db` в WAL-режиме даёт битую копию.** Только `sqlite3 .backup`, и
  проверять `integrity_check` уже на копии, а не на источнике.
- **`subURI` перекрывает хост из запроса.** Если однажды записан — подписка
  навсегда прибита к старому адресу, смена IP её не чинит.

## Отчёт

Что сделано и **чем проверено** (PASS теста, exit IP, коды ответов), что пользователь
должен обновить на устройствах (ссылка, Endpoint, tg-ссылка), что осталось и какие
риски. Секреты в отчёт не копировать: «пароль выдал в чате выше» / «ссылка в чате».

## Файлы

- `scripts/server_audit.sh` — read-only сбор состояния сервера (включая IPv6).
- `scripts/state_check.sh` — PASS/WARN/FAIL по факту, `--json`, `--strict`.
- `scripts/verify_vless.py` — сквозная проверка VLESS Reality через локальный socks;
  `--family 4|6|auto`, `--expect-family`.
- `scripts/add_client.sh` — клиент с лимитами через API панели + ссылка/подписка.
- `scripts/sub_setup.sh` — включить подписку, выдать `subId`, проверить запросом.
- `scripts/watchdog.sh` — сторож: панель, порт, туннель, алерт в Telegram.
- `scripts/backup-db.sh`, `scripts/restore-db.sh` — БД x-ui: `.backup`, `age`,
  `rclone`, `.db.gz`/`.db.age` при восстановлении.
- `scripts/install_singbox_hysteria2.sh` — второй транспорт Hysteria2.
- `scripts/check_no_secrets.sh` — страж репозитория: IP, пароли, ключи, ссылки.
- `scripts/rollback.sh` — откат установки (панель, пользователь, SSH), с подтверждением.
- `scripts/lib/xui.py` — общая библиотека: БД, API панели, ссылки, подписка.
- `systemd/` — таймеры бэкапа и сторожа.
- `tests/` — bats-тесты на фикстурах и фальшивой панели (обе схемы API).
- `references/reality-sni.md` — как выбрать SNI и не сломать Reality.
- `references/reality-link-format.md` — из чего собирается `vless://`.
- `references/vless-tls.md` — вариант с доменом и сертификатом.
- `references/subscription.md` — подписка: настройки, TLS, клиенты.
- `references/watchdog.md` — сторож и алерты.
- `references/backup-offsite.md` — бэкап наружу (rclone + age) и восстановление.
- `references/ip-migration.md` — переезд на новый IP.
- `references/ipv6.md` — IPv6: утечки и v6-inbound.
- `references/hysteria2.md` — второй транспорт на UDP.
- `references/fallback-nginx.md` — страница-заглушка для TLS-варианта.

## Обслуживание навыка

Навык живёт в репозитории и ставится через `install.sh`, поэтому при правках:

- Тесты — `bats tests/` (нужны `bats`, `sqlite3`, `python3`); они не требуют VPN и
  поднимают фальшивую панель обеих схем API. Правка без зелёных тестов не считается
  сделанной.
- CI (`.github/workflows/ci.yml`): `check_no_secrets.sh --all`, `shellcheck -x -S
  warning`, `py_compile`, `bats`. Локально те же команды — до коммита.
- `REPO_URL` переопределяется окружением, и к нему **нельзя дописывать `.git`**:
  иначе установщик не проверить на локальном клоне. Тест: `REPO_URL=file:///path/to/clone
  ./install.sh --dir /tmp/skilltest`.
- Примеры адресов — только TEST-NET `203.0.113.0/24`; «похожий на настоящий» пример
  сканер не отличит от утечки.
- `check_no_secrets.sh` не должен срабатывать на прозе: ключами считать
  `password|passwd|passphrase|secret|api_key|token` (не одинокий `pass`), а значение
  обязано содержать ASCII-букву или цифру.
- Перед коммитом: `bash scripts/check_no_secrets.sh` и `git show --stat`;
  `__pycache__/` и `*.pyc` держать в `.gitignore`.
