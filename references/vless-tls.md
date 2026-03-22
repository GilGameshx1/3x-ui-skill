# Настройка VLESS TLS (с доменом)

Используйте этот файл, когда у пользователя есть домен и он хочет VLESS TLS вместо Reality.

## Требования

- Домен зарегистрирован и A-запись указывает на IP сервера
- DNS распространён (проверьте: `nslookup {domain}` возвращает IP сервера)
- Порты 80 и 443 открыты в UFW (уже сделано в Шаге 8)

---

## Шаг 1: Проверка DNS

```bash
nslookup {domain}
```

Должен вернуть IP сервера. Если нет — подождите 5-10 минут для распространения DNS.

Можно также проверить с сервера:
```bash
ssh {nickname} "sudo apt install -y dnsutils > /dev/null 2>&1; nslookup {domain}"
```

---

## Шаг 2: Получение SSL-сертификата

Используйте встроенное управление сертификатами x-ui:
```bash
ssh {nickname} "sudo x-ui cert"
```

Это откроет интерактивное меню. Выберите:
1. "Get SSL" (опция 1)
2. Введите имя домена
3. Используйте порт 80 (по умолчанию)

**Альтернативно**, неинтерактивно с acme.sh:
```bash
ssh {nickname} "sudo apt install -y socat && curl https://get.acme.sh | sh && sudo ~/.acme.sh/acme.sh --issue -d {domain} --standalone --httpport 80 && sudo ~/.acme.sh/acme.sh --install-cert -d {domain} --key-file /root/cert/{domain}/privkey.pem --fullchain-file /root/cert/{domain}/fullchain.pem --reloadcmd 'x-ui restart'"
```

Файлы сертификата будут расположены:
```
/root/cert/{domain}/fullchain.pem  # сертификат
/root/cert/{domain}/privkey.pem    # приватный ключ
```

---

## Шаг 3: Настройка панели с SSL

Примените сертификат к панели:
```bash
ssh {nickname} "sudo /usr/local/x-ui/x-ui cert -webCert /root/cert/{domain}/fullchain.pem -webCertKey /root/cert/{domain}/privkey.pem"
ssh {nickname} "sudo x-ui restart"
```

Теперь панель обслуживает HTTPS. Доступ через SSH-туннель:
```bash
ssh -L {panel_port}:127.0.0.1:{panel_port} {nickname}
```

Затем откройте: `https://127.0.0.1:{panel_port}/{web_base_path}` (браузер предупредит о несоответствии сертификата — это нормально, примите его).

---

## Шаг 4: Изменение учётных данных панели

Соединение зашифровано (SSH-туннель + HTTPS), можно безопасно установить свои учётные данные:
```bash
ssh {nickname} "sudo x-ui setting -username {new_username} -password {new_password}"
ssh {nickname} "sudo x-ui restart"
```

---

## Шаг 5: Включение 2FA в панели (рекомендуется)

Предложите пользователю:
1. Открыть панель через SSH-туннель: `https://127.0.0.1:{panel_port}/{web_base_path}`
2. Перейти в Settings -> Account
3. Включить "Two-Factor Authentication"
4. Отсканировать QR-код приложением-аутентификатором (Google Authenticator, Microsoft Authenticator)
5. Ввести 6-значный код для подтверждения

---

## Шаг 6: Создание входящего подключения VLESS TLS

**Вход в API:**
```bash
ssh {nickname} 'PANEL_PORT={panel_port}; curl -sk -c /tmp/3x-cookie -b /tmp/3x-cookie -X POST "https://127.0.0.1:${PANEL_PORT}/{web_base_path}/login" -H "Content-Type: application/x-www-form-urlencoded" -d "username={panel_username}&password={panel_password}"'
```

**Генерация UUID:**
```bash
ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* uuid"
```

**Создание входящего подключения VLESS TLS на порту 443:**
```bash
ssh {nickname} 'PANEL_PORT={panel_port}; curl -sk -c /tmp/3x-cookie -b /tmp/3x-cookie -X POST "https://127.0.0.1:${PANEL_PORT}/{web_base_path}/panel/api/inbounds/add" -H "Content-Type: application/json" -d '"'"'{
  "up": 0,
  "down": 0,
  "total": 0,
  "remark": "vless-tls",
  "enable": true,
  "expiryTime": 0,
  "listen": "",
  "port": 443,
  "protocol": "vless",
  "settings": "{\"clients\":[{\"id\":\"{CLIENT_UUID}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"user1\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true}],\"decryption\":\"none\",\"fallbacks\":[]}",
  "streamSettings": "{\"network\":\"tcp\",\"security\":\"tls\",\"externalProxy\":[],\"tlsSettings\":{\"serverName\":\"{domain}\",\"minVersion\":\"1.2\",\"maxVersion\":\"1.3\",\"cipherSuites\":\"\",\"rejectUnknownSni\":false,\"disableSystemRoot\":false,\"enableSessionResumption\":false,\"certificates\":[{\"certificateFile\":\"/root/cert/{domain}/fullchain.pem\",\"keyFile\":\"/root/cert/{domain}/privkey.pem\",\"ocspStapling\":3600,\"oneTimeLoading\":false,\"usage\":\"encipherment\",\"buildChain\":false}],\"alpn\":[\"h2\",\"http/1.1\"]},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}",
  "sniffing": "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}",
  "allocate": "{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"
}'"'"''
```

---

## Шаг 7: Получение ссылки для подключения

```bash
ssh {nickname} 'PANEL_PORT={panel_port}; curl -sk -b /tmp/3x-cookie "https://127.0.0.1:${PANEL_PORT}/${web_base_path}/panel/api/inbounds/list" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for inb in data.get(\"obj\", []):
    if inb.get(\"protocol\") == \"vless\" and \"tls\" in inb.get(\"streamSettings\", \"\"):
        settings = json.loads(inb[\"settings\"])
        stream = json.loads(inb[\"streamSettings\"])
        client = settings[\"clients\"][0]
        uuid = client[\"id\"]
        port = inb[\"port\"]
        sni = stream.get(\"tlsSettings\", {}).get(\"serverName\", \"\")
        flow = client.get(\"flow\", \"\")
        link = f\"vless://{uuid}@{sni}:{port}?type=tcp&security=tls&sni={sni}&fp=chrome&flow={flow}#vless-tls\"
        print(link)
        break
"'
```

---

## Шаг 8: Автоматическое продление сертификата через Crontab

Сертификат автоматически продлевается через cron-задачу acme.sh. Убедитесь, что порт 80 остаётся открытым (уже сделано при настройке сервера).

Проверьте, что автопродление настроено:
```bash
ssh {nickname} "sudo crontab -l 2>/dev/null | grep acme"
```

Должна отображаться cron-задача для продления acme.sh.

---

## Завершение

После получения ссылки вернитесь к основному SKILL.md **Шаг 20** (Установка клиента Hiddify).

---

## Устранение неполадок

| Проблема | Решение |
|----------|---------|
| DNS не резолвится | Подождите 10-15 минут, проверьте настройки домена |
| Ошибка получения сертификата | Убедитесь, что порт 80 открыт и не занят |
| Сертификат не продлевается | Проверьте cron: `sudo crontab -l` |
| Панель недоступна | Используйте SSH-туннель |
| Ошибка SSL в браузере | Это нормально при доступе по IP, используйте домен |
