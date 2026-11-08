# Hysteria2 как второй транспорт (sing-box)

Reality — TCP-транспорт с маскировкой под чужой TLS-сайт. Hysteria2 — QUIC поверх UDP
с собственным TLS и HTTP-маскарадом. Это не замена, а страховка: сети, которые режут
TCP-профили или душат скорость на дальних маршрутах, часто пропускают QUIC, и наоборот.

| | VLESS Reality (Xray) | Hysteria2 (sing-box) |
|---|---|---|
| Транспорт | TCP + TLS-мимикрия | QUIC/UDP, TLS 1.3 |
| Порт | 443/tcp | 443/udp (или 8443, 20000+) |
| Домен | не нужен | не нужен (self-signed), желателен для acme |
| Маскировка | чужой сайт в handshake | HTTP-маскарад после handshake |
| Сильные стороны | проходит там, где UDP закрыт; не боится QoS | быстрее на потерях и мобильных сетях, дешевле handshake |
| Слабые стороны | TCP-блокировки, «медленный» на RTT > 200 мс | UDP-фильтры, троттлинг UDP, MTU |
| Клиенты | любые Xray/v2ray | Hiddify, NekoBox, Streisand, sing-box |

Держите оба inbound'а: TCP/443 у Xray и UDP/443 у sing-box не конфликтуют.

## Когда включать

- Reality работает, но скорость на дальнем сервере неудовлетворительная.
- Провайдер режет UDP только частично — Hysteria2 «добирает» там, где TCP душат.
- Мобильные клиенты (Hiddify/NekoBox) — QUIC лучше переносит смену сети и потери.

Не включать, если у пользователей сеть блокирует UDP целиком (корпоративные/учебные сети):
тогда Hysteria2 просто не подключится, а Reality останется рабочим.

## UDP/443: что меняется

- Порт занимает **UDP**, TCP/443 свободен для Xray/nginx. В firewall нужны оба правила.
- Handshake QUIC = 1 RTT, поэтому «пинг» в клиенте ниже, чем у TCP-туннеля.
- Состояние держится в ядре (conntrack). При тысячах соединений помогает
  `net.core.rmem_max` / `net.core.wmem_max` ≥ 16 МБ (по умолчанию 208 КБ).
- UDP не любит потери: при 5–10 % потерь QUIC всё равно быстрее TCP, но при 30 % — уже нет.

## Установка sing-box

```bash
# официальный установщик: ставит пакет, /usr/bin/sing-box, unit sing-box.service
curl -fsSL https://sing-box.app/install.sh | sh
sing-box version          # нужен 1.11+; примеры проверены на 1.14

# альтернатива для Debian/Ubuntu — репозиторий SagerNet
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
sudo chmod a+r /etc/apt/keyrings/sagernet.asc
echo 'Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc' | sudo tee /etc/apt/sources.list.d/sagernet.sources
sudo apt update && sudo apt install -y sing-box
```

Пакетный unit работает от пользователя `sing-box` и читает `-C /etc/sing-box`,
состояние пишет в `/var/lib/sing-box`. Это важно для прав на сертификаты (ниже).
Свой unit скрипт `scripts/install_singbox_hysteria2.sh` ставит только если пакетного нет.

## TLS

Hysteria2 всегда работает через TLS 1.3, ALPN `h3`. Три варианта, по возрастанию сложности:

### 1. acme.sh, домен (рекомендуется, если домен есть)

```bash
curl https://get.acme.sh | sh -s email=<EMAIL>
~/.acme.sh/acme.sh --issue -d vpn.example.com --standalone -m <EMAIL>
~/.acme.sh/acme.sh --install-cert -d vpn.example.com \
  --key-file /etc/sing-box/certs/privkey.pem \
  --fullchain-file /etc/sing-box/certs/fullchain.pem \
  --reloadcmd "systemctl restart sing-box"
```

`--standalone` требует свободный TCP/80 на время выпуска. Если 80 занят nginx —
`--webroot /var/www/html` (файл `.well-known/acme-challenge/` должен отдаваться).

### 2. acme.sh, сертификат на IP (shortlived)

Let's Encrypt выдаёт сертификаты на IP-адрес только в профиле `shortlived` — срок
около 6 дней, продление каждые ~3 дня (cron acme.sh делает это сам).
Валидация — http-01 или tls-alpn-01, то есть **обязателен свободный TCP/80**;
dns-01 для IP невозможен.

```bash
~/.acme.sh/acme.sh --issue --server letsencrypt --cert-profile shortlived --days 3 \
  -d 203.0.113.10 --standalone -m <EMAIL>
```

```bash
~/.acme.sh/acme.sh --install-cert -d 203.0.113.10 \
  --key-file /etc/sing-box/certs/privkey.pem \
  --fullchain-file /etc/sing-box/certs/fullchain.pem \
  --reloadcmd "systemctl restart sing-box"
```

Плюс: клиенту не нужен `insecure=1`, сертификат настоящий. Минус: IP «засвечен»
в Certificate Transparency, а при смене IP сертификат надо выпускать заново.

### 3. self-signed

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 365 -nodes \
  -keyout /etc/sing-box/certs/privkey.pem -out /etc/sing-box/certs/fullchain.pem \
  -subj "/CN=203.0.113.10" \
  -addext "subjectAltName=IP:203.0.113.10" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=serverAuth"
```

- **EC P-256, не Ed25519.** Клиент sing-box по умолчанию повторяет QUIC-handshake Chrome,
  а Chrome не предлагает Ed25519 — handshake молча падает.
- Клиенту нужен `insecure=1` в ссылке (или `pinSHA256` в клиенте).
- SAN должен содержать именно тот адрес, по которому подключаются: IP или DNS-имя.

### Права на файлы

Сервис работает от `sing-box`, поэтому `600 root:root` на ключе = «не читается» и
`Failed to start`. Рабочая схема:

```bash
chown -R root:sing-box /etc/sing-box/certs
chmod 750 /etc/sing-box/certs
chmod 644 /etc/sing-box/certs/fullchain.pem
chmod 640 /etc/sing-box/certs/privkey.pem
```

Конфиг с паролем: `640 root:sing-box` (если сервис от root — `600 root:root`).

## Конфиг

`/etc/sing-box/config.json`. Скрипт `scripts/install_singbox_hysteria2.sh` собирает
такой inbound и **сохраняет чужие inbound'ы**, если файл уже существует:

```json
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "ignore_client_bandwidth": true,
      "users": [ { "name": "default", "password": "<PASSWORD>" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      },
      "masquerade": { "type": "proxy", "url": "https://www.microsoft.com/", "rewrite_host": true },
      "obfs": { "type": "salamander", "password": "<OBFS_PASSWORD>" }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
```

- `listen: "::"` — dual-stack; на сервере без IPv6 работает и для IPv4.
- `up_mbps` / `down_mbps` **не задавайте**, если не включаете Brutal: без них сервер
  использует BBR, который сам подстраивается под канал.
- `ignore_client_bandwidth: true` — сервер не верит заявленной клиентом полосе
  (иначе клиент может выпросить больше, чем есть в канале).
- `alpn: ["h3"]` — обязательный профиль для QUIC; клиенты обязаны совпасть.
- Проверка: `sing-box check -c /etc/sing-box/config.json` (файлы сертификатов должны
  существовать — check их открывает).

## Маскарад

На неаутентифицированный запрос (браузер, сканер) inbound отвечает как обычный сайт:

| Значение | Поведение |
|---|---|
| `{"type":"proxy","url":"https://www.microsoft.com/","rewrite_host":true}` | reverse-proxy на чужой сайт; `Host` подменяется на целевой |
| `{"type":"file","directory":"/var/www/html"}` | статика с диска; удобно, если nginx уже отдаёт заглушку |
| `{"type":"string","status_code":200,"content":"..."}` | фиксированный ответ, без сети |
| не задан | 404 — сразу видно, что на порту не веб-сервер |

Строкой тоже можно: `"masquerade": "https://www.microsoft.com/"` или `"file:///var/www/html"`.
Прокси-маскарад не должен указывать на сайт, заблокированный у пользователя, иначе
проверяющий увидит таймаут вместо страницы.

## obfs salamander

Обфускация QUIC-пакетов: убирает характерные сигнатуры Hysteria2, из-за которых
некоторые провайдеры сбрасывают UDP-поток или включают QoS.

- Включается на обеих сторонах: сервер `obfs.type=salamander`, клиент `obfs=salamander`.
- Пароль обфускации — **отдельный** от пароля пользователя; в ссылке это `obfs-password`.
- Стоимость — несколько байт на пакет и несовместимость со старыми клиентами.
- Начинайте без obfs. Если UDP душат — включайте; если и это не помогло, дело не в DPI.

## Ссылка

```
hysteria2://<PASSWORD>@<HOST>:<PORT>/?insecure=1&sni=<SNI>&obfs=salamander&obfs-password=<OBFS>#<TAG>
```

| Параметр | Откуда |
|---|---|
| auth (до `@`) | `inbounds[].users[].password`, percent-encoded |
| HOST/PORT | публичный адрес и `listen_port`; IPv6 — в квадратных скобках |
| `insecure=1` | только для self-signed |
| `sni` | `tls.server_name`; для self-signed без домена можно опустить |
| `obfs`, `obfs-password` | блок `obfs`; если obfs нет — параметров нет |
| `pinSHA256` | hex SHA-256 сертификата — альтернатива `insecure=1` |

Скрипт печатает ссылку один раз в stdout; в файлы она не попадает. Сохраните её
в менеджере паролей — восстановить пароль из конфига можно, но это лишний шаг.

## Клиенты

| Клиент | Платформы | Замечание |
|---|---|---|
| Hiddify | Android, iOS, Windows, macOS, Linux | импорт `hysteria2://` из буфера; самый предсказуемый |
| NekoBox | Android | ядро sing-box, поддерживает obfs salamander |
| Streisand | iOS, macOS | импорт hy2 в свежих версиях; если ссылка не принимается — Hiddify |
| sing-box | CLI, все ОС | эталонная реализация, удобно для проверки |

В клиенте должны совпасть: адрес, порт **UDP**, пароль, `sni`, obfs-пароль.
Ошибка «authentication failed» = пароль; «timeout» = UDP не доходит.

## Проверка снаружи

Порядок — от дешёвого к доказательному:

```bash
# 1. Порт вообще виден? UDP не отвечает на connect, поэтому open|filtered — норма
nmap -sU -p 443 203.0.113.10

# 2. Сервер слушает и не падает
ss -lunp | grep ':443'
journalctl -u sing-box -e --no-pager | tail -20

# 3. TLS-handshake по QUIC (OpenSSL 3.2+, иначе шаг пропустить)
openssl s_client -quic -alpn h3 -connect 203.0.113.10:443 -servername vpn.example.com </dev/null

# 4. Доказательство: туннель и внешний IP через него
#    (клиент sing-box на другой машине, socks 127.0.0.1:1080)
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
```

Шаг 4 — единственный, который подтверждает, что работает именно Hysteria2:
UDP-порт может быть «open|filtered» и при полностью чёрной дыре.

Сам сервер проверить нечем: `nc -zu` и подобные «UDP-пинги» врут. Нужен внешний хост.

## Типичные поломки

| Симптом | Причина | Что делать |
|---|---|---|
| Клиент: timeout, порт в nmap filtered | UDP режется провайдером/хостером/QoS | другой порт (8443, 20000–50000), `--obfs salamander`, в крайнем случае — Reality |
| Handshake проходит, крупные передачи рвутся | MTU/фрагментация (QUIC ~1200 байт) | убрать двойной NAT/VPN, отключить IPv6 в клиенте, поднять MTU на интерфейсе |
| «authentication failed» | несовпадение пароля (или obfs-пароля) | пересоздать ссылку из конфига, проверить `users[].password` |
| «certificate verify failed» | self-signed без `insecure=1`, либо SAN не тот | добавить `insecure=1` / `pinSHA256`, перевыпустить серт с нужным SAN |
| Сервис не стартует: `read certificate: permission denied` | ключ `600 root:root`, сервис от `sing-box` | `chown root:sing-box`, `chmod 640` на ключ |
| `sing-box check` падает на `address already in use` при старте | порт занят другим процессом | `ss -lunp \| grep :443`, освободить или сменить порт |
| Работает 2 минуты и умирает | клиент выбрал IPv6, а на сервере IPv6 сломан | `listen: "::"` оставить, но проверить `ip -6 addr`; в клиенте отключить IPv6 |
| Порт открыт, но `ufw` всё равно режет | правило добавлено для tcp | `ufw allow 443/udp`, проверить `ufw status verbose` |
| Низкая скорость при хорошем канале | заданы `up_mbps`/`down_mbps` без Brutal | убрать эти поля, оставить BBR |
| Сканер видит «404» на порту | маскарад не настроен | `--masquerade https://...` или `file:///var/www/html` |

## Чек-лист после установки

```bash
sing-box check -c /etc/sing-box/config.json     # конфиг валиден
systemctl is-active sing-box                    # сервис жив
ss -lunp | grep ':443'                          # UDP слушается
ufw status | grep 443                           # разрешён udp, не tcp
journalctl -u sing-box -e | grep -i error       # нет ошибок TLS/порта
```

Плюс одно реальное подключение клиентом с внешней сети — только оно считается проверкой.

## Ограничения

- Hysteria2 не маскируется под чужой сайт в TLS-handshake так, как Reality: сертификат
  на IP виден в CT, self-signed виден сканеру. Маскарад закрывает только HTTP-уровень.
- Порт UDP/443 у хостера может быть занят чужим сервисом или закрыт на уровне облака
  (security group) — тогда ufw бесполезен, правьте правила у провайдера.
- Скрипт не настраивает Brutal и не выдаёт сертификаты без acme.sh/openssl; живой UDP
  на конкретном сервере и хостере проверяется только снаружи.
