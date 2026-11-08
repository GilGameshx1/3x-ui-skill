# Подписка вместо ручных ссылок

Одна ссылка на устройство вместо `vless://` вручную. Клиент сам забирает список
входящих, а после смены IP панель отдаёт в подписке уже новый адрес — рассылать
ничего не нужно.

## Как это устроено

- У каждого клиента в панели есть `subId` (16 hex). Подписка — это
  `GET https://<host>:<subPort><subPath><subId>`.
- Хост берётся из запроса клиента; поэтому подписка переживает смену IP, если
  клиент ходит по домену. С `subURI`/`subDomain` адрес фиксируется жёстко.
- Формат ответа зависит от `User-Agent`: `v2rayN/…` → base64-список ссылок,
  `clash` → YAML, `sing-box` → JSON. Панель делает это сама.
- Настройки живут в таблице `settings`: `subEnable`, `subPort`, `subPath`,
  `subDomain`, `subURI`, `subCertFile`, `subKeyFile`.

## Включение

```bash
# 1. Включить и задать порт/путь (по умолчанию 2096 и /sub/)
scripts/sub_setup.sh --sub-port 2096 --sub-path /sub/

# 2. Выдать subId клиентам, созданным до включения подписки
scripts/sub_setup.sh --assign-subids

# 3. Открыть порт наружу (иначе подписка доступна только с сервера)
ufw allow 2096/tcp
```

Скрипт сам перезапускает панель и проверяет подписку запросом: `PASS` означает,
что по URL реально пришли ссылки, а не пустой ответ.

## TLS для подписки

Подписка по `http://` светит `subId` в открытом виде — это пропуск к ссылкам.
Минимум — TLS на IP (сертификат Let's Encrypt на 6 дней, см.
`xray-3xui-operations.md`), затем указать его панели:

```bash
acme.sh --issue -d <SERVER_IP> --standalone --cert-profile shortlived --keylength ec-256
acme.sh --install-cert -d <SERVER_IP> --ecc \
  --key-file  /root/cert/sub/privkey.pem \
  --fullchain-file /root/cert/sub/fullchain.pem \
  --reloadcmd "systemctl restart x-ui"
sqlite3 /etc/x-ui/x-ui.db "update settings set value='/root/cert/sub/fullchain.pem' where key='subCertFile';"
sqlite3 /etc/x-ui/x-ui.db "update settings set value='/root/cert/sub/privkey.pem' where key='subKeyFile';"
```

Наличие обоих файлов само переключает схему на `https` — отдельного флага нет.
Проверка:

```bash
curl -sI https://<host>:2096/sub/<subId> | head -3
```

## Клиенты

- **Hiddify** — «Добавить профиль из ссылки», вставляется URL подписки, обновление
  по расписанию (по умолчанию раз в 12 ч).
- **v2rayNG / NekoBox** — «Импорт из буфера обмена» понимает URL подписки;
  дальше «Обновить подписку».
- **Streisand / V2Box (iOS)** — Add subscription → URL.
- **NekoRay / v2rayN (десктоп)** — Subscriptions → Add.

## Грабли

- **Пустой ответ 200.** У клиента нет `subId` либо запрошен чужой `subId`.
  Проверять по конкретному клиенту: `scripts/add_client.sh` печатает его subId.
- **`subURI` перекрывает всё.** Если он когда-то был записан (например, старым
  IP), панель больше не подставляет хост из запроса. Смотреть
  `select value from settings where key='subURI';` и чистить, если не нужен.
- **Порт закрыт файрволом или слушает только localhost** — с сервера всё
  работает, снаружи нет. Проверка снаружи: `curl` с другой машины, а не с самого
  сервера.
- **TLS включён, а клиент ходит на `http://`** — часть клиентов молча не
  обновляется. Ссылку выдавать ровно с той схемой, которую отдаёт панель.
- **Подписка не заменяет проверку туннеля.** Успешный `GET` подписки значит лишь
  «панель жива». Работоспособность проверяется `verify_vless.py` по ссылке из
  подписки.
- **`subId` — секрет.** Кто знает URL, получает рабочие конфиги. В отчётах и
  тикетах его не публиковать.
