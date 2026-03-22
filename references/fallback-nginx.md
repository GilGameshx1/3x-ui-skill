# Конфигурация страницы заглушки Nginx

Этот справочный файл настраивает страницу-заглушку (камуфляж) для настроек VLESS TLS. Когда кто-то посещает ваш домен напрямую, он видит обычный веб-сайт вместо ошибки.

---

## Когда использовать

- Вы используете VLESS TLS (не Reality)
- Вы хотите скрыть факт запуска прокси
- Вам нужна заглушка для обычных подключений на порту 443

---

## Шаг 1: Установка Nginx

```bash
ssh {nickname} "sudo apt install -y nginx"
```

---

## Шаг 2: Создание HTML-страницы заглушки

```bash
sudo tee /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Добро пожаловать</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            margin: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
        }
        .container {
            text-align: center;
            padding: 2rem;
        }
        h1 { font-size: 2.5rem; margin-bottom: 0.5rem; }
        p { opacity: 0.8; font-size: 1.1rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Добро пожаловать</h1>
        <p>Это личный веб-сайт.</p>
    </div>
</body>
</html>
EOF
```

---

## Шаг 3: Настройка Nginx как заглушки

Создайте конфигурацию Nginx, которая обслуживает статическую страницу на порту 80 и перенаправляет порт 443 в Xray:

```bash
sudo tee /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate /root/cert/{domain}/fullchain.pem;
    ssl_certificate_key /root/cert/{domain}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        # Страница заглушки, если Xray не обрабатывает соединение
        root /var/www/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
}
EOF
```

---

## Шаг 4: Включение и перезапуск Nginx

```bash
sudo systemctl enable nginx
sudo systemctl restart nginx
sudo systemctl status nginx
```

---

## Шаг 5: Проверка работы заглушки

Проверьте с локального компьютера:
```bash
curl -k https://{domain}
```

Должна вернуться HTML-страница заглушки.

---

## Интеграция с 3x-ui

Панель 3x-ui с VLESS TLS будет обрабатывать фактические прокси-подключения на порту 443.
Nginx служит заглушкой для обычного HTTP/HTTPS трафика, который не соответствует протоколу VLESS.

Эта настройка обеспечивает:
- **Правдоподобное отрицание** — выглядит как обычный веб-сайт
- **Страница заглушки** — посетители видят контент вместо ошибок
- **SSL терминация** — Nginx обрабатывает SSL, Xray обрабатывает прокси

---

## Устранение неполадок

| Проблема | Решение |
|----------|---------|
| Nginx не запускается | Проверьте `sudo nginx -t` на ошибки конфигурации |
| Порт 443 уже используется | `sudo ss -tlnp | grep 443` для поиска конфликта |
| Сертификат не найден | Повторно запустите настройку сертификата из vless-tls.md |
| Заглушка показывает ошибку | Проверьте логи Nginx: `sudo tail -f /var/log/nginx/error.log` |
| Доступен только HTTP | Проверьте конфигурацию SSL в sites-available |

---

## Дополнительные настройки

### Добавление редиректа HTTP на HTTPS

```bash
sudo tee /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Редирект на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate /root/cert/{domain}/fullchain.pem;
    ssl_certificate_key /root/cert/{domain}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        root /var/www/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
}
EOF

sudo systemctl restart nginx
```

### Включение кэширования

Для улучшения производительности добавьте в блок `http`:

```bash
sudo tee -a /etc/nginx/nginx.conf << 'EOF'

# Кэширование статического контента
http {
    # ... существующие настройки ...
    
    # Кэш для статики
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
```
