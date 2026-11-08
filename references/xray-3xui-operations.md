# 3x-ui / Xray: операции

## База

Рабочая БД — `/etc/x-ui/x-ui.db` (SQLite). Файл `/usr/local/x-ui/x-ui.db` нулевого
размера — приманка, не путать.

```bash
sqlite3 /etc/x-ui/x-ui.db ".tables"
sqlite3 /etc/x-ui/x-ui.db "select key,value from settings;"          # webPort, webBasePath, certs, secret
sqlite3 /etc/x-ui/x-ui.db "select id,remark,enable,listen,port,protocol from inbounds;"
sqlite3 /etc/x-ui/x-ui.db "select settings from inbounds where id=1;" | python3 -m json.tool
sqlite3 /etc/x-ui/x-ui.db "select stream_settings from inbounds where id=1;" | python3 -m json.tool
```

`json_pretty()` в системном sqlite3 отсутствует — форматировать через `python3 -m json.tool`.

Из `stream_settings` берутся `realitySettings.dest/serverNames/shortIds/privateKey`.
Из `settings` входящего — клиенты (uuid, flow, email, subId) и `totalGB`/`expiryTime`.

## Public key

Не доверять сохранённому `settings.publicKey` и тем более гайду. Выводить:

```bash
/usr/local/x-ui/bin/xray-linux-amd64 x25519 -i <privateKey>
# PrivateKey: ...   Password: <это и есть public key, base64url>
```

## Ссылка VLESS Reality

```
vless://<UUID>@<IP>:<PORT>?type=tcp&security=reality&pbk=<PBK>&fp=chrome&sni=<SNI>&sid=<SID>&spx=%2F&flow=xtls-rprx-vision#<TAG>
```

- `flow` только если он есть у клиента в БД; без flow параметр не ставить.
- `pbk` в base64url без паддинга; панель экранирует `/` и `=` как `%2F` `%3D` — оба
  варианта клиенты принимают.
- Подписка: `https://<IP>:<subPort>/sub/<subId>` — панель собирает ссылку из хоста запроса,
  поэтому после смены IP отдаёт уже новый адрес без правок.

## Сертификаты панели и подписки

Ключи в `settings`: `webCertFile`, `webKeyFile`, `subCertFile`, `subKeyFile`.

```bash
acme.sh --issue -d <IP> --standalone --cert-profile shortlived --keylength ec-256
acme.sh --install-cert -d <IP> --ecc \
  --key-file /root/cert/newip/privkey.pem --fullchain-file /root/cert/newip/fullchain.pem \
  --reloadcmd "systemctl restart x-ui"
sqlite3 /etc/x-ui/x-ui.db "update settings set value='/root/cert/newip/fullchain.pem' where key in ('webCertFile','subCertFile');"
systemctl restart x-ui
```

Проверка, что панель отдаёт именно новый серт:

```bash
echo | openssl s_client -connect <IP>:<webPort> 2>/dev/null | openssl x509 -noout -dates -ext subjectAltName
curl -s -o /dev/null -w 'verify:%{ssl_verify_result} code:%{http_code}\n' https://<IP>:<webPort><webBasePath>
```

`ssl_verify_result=0` — цепочка валидна. Серт отдаётся только после рестарта x-ui.

## Логин в панель

Логин в БД: `select username from users;`. Проверка пароля — реальным запросом:

```bash
curl -sk -X POST "https://127.0.0.1:<webPort><webBasePath>/login" \
  -d "username=<u>&password=<p>" -w '\nHTTP:%{http_code}\n'
# {"success":true,...} — пароль верный
```

## Прочее

- `x-ui restart` перезапускает и панель, и xray (клиенты переподключаются сами).
- Сброс пароля: `x-ui setting -reset`. Логи: `journalctl -u x-ui -f`, `x-ui log`.
- Xray-конфиг генерируется в `/usr/local/x-ui/bin/config.json` — смотреть его, а не БД,
  когда нужно понять, что реально запущено (там же `routing` и `outbounds`).
- Бэкап: `cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak.$(date +%F)`.
- Xray 26.x предупреждает про VLESS без flow — это deprecation, не ошибка.
