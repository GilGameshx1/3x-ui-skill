# Fallback Nginx Page Configuration

This reference file configures a camouflage/fallback page for VLESS TLS setups.
When someone visits your domain directly, they see a normal website instead of an error.

---

## When to Use

- You're using VLESS TLS (not Reality)
- You want to hide the fact that you're running a proxy
- You need a fallback for non-proxy connections on port 443

---

## Step 1: Install Nginx

```bash
ssh {nickname} "sudo apt install -y nginx"
```

---

## Step 2: Create Fallback HTML Page

```bash
sudo tee /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
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
        <h1>Welcome</h1>
        <p>This is a personal website.</p>
    </div>
</body>
</html>
EOF
```

---

## Step 3: Configure Nginx as Fallback

Create Nginx config that serves the static page on port 80 and forwards port 443 to Xray:

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
        # Fallback page if Xray doesn't handle the connection
        root /var/www/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
}
EOF
```

---

## Step 4: Enable and Restart Nginx

```bash
sudo systemctl enable nginx
sudo systemctl restart nginx
sudo systemctl status nginx
```

---

## Step 5: Verify Fallback Works

Test from your local machine:
```bash
curl -k https://{domain}
```

Should return the HTML fallback page.

---

## Integration with 3x-ui

The 3x-ui panel with VLESS TLS will handle the actual proxy connections on port 443.
Nginx serves as a fallback for regular HTTP/HTTPS traffic that doesn't match the VLESS protocol.

This setup provides:
- **Plausible deniability** — looks like a normal website
- **Fallback page** — visitors see content instead of errors
- **SSL termination** — Nginx handles SSL, Xray handles proxy

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Nginx won't start | Check `sudo nginx -t` for config errors |
| Port 443 already in use | `sudo ss -tlnp | grep 443` to find conflict |
| Certificate not found | Re-run certificate setup from vless-tls.md |
| Fallback shows error | Check Nginx logs: `sudo tail -f /var/log/nginx/error.log` |
