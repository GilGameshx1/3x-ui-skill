# Аудит и укрепление VPN-сервера

## Чек-лист аудита (что смотреть и что считать нормой)

| Проверка | Команда | Норма |
|---|---|---|
| ОС/ядро/uptime | `cat /etc/os-release; uname -r; uptime` | ядро = установленным modules |
| IPv4 на интерфейсе | `ip -4 addr; ip route` | известны все адреса и источник NAT |
| Слушающие порты | `ss -tulpn` | каждый порт объясним |
| Юниты | `systemctl list-units --all \| grep -iE 'x-ui\|xray\|wg\|v2ray\|sing-box'` | запущены нужные |
| Контейнеры | `docker ps -a` | нет рестарт-лупов, нет лишних |
| Файрвол | `ufw status verbose` | включён, порты по списку |
| SSH | `sshd -T \| grep -E '^(port\|permitrootlogin\|passwordauthentication\|pubkeyauthentication)'` | пароли off, вход по ключу |
| Ключи | `ls -la /root/.ssh; wc -l authorized_keys` | только свои ключи |
| fail2ban | `fail2ban-client status` | sshd jail активен |
| TCP/ICMP | `sysctl net.ipv4.tcp_congestion_control net.ipv4.icmp_echo_ignore_all` | bbr, ping выключен |
| Серты | `openssl x509 -in ... -noout -dates -ext subjectAltName` | SAN совпадает с IP/доменом, не истёк |
| Ресурсы | `df -h /; free -h; du -sh /var/log /var/lib/docker` | диск < 80%, RAM с запасом |
| Обновления | `apt list --upgradable` | пусто или понятно почему |
| Входы | `last -n 10; grep Accepted /var/log/auth.log` | только свои IP |
| Клиентский трафик | `sqlite3 /etc/x-ui/x-ui.db 'select * from client_traffics;'` | соответствует ожиданиям |

## BBR

```bash
modprobe tcp_bbr || { depmod -a $(uname -r); modprobe tcp_bbr; }
sysctl net.ipv4.tcp_available_congestion_control   # должен появиться bbr
cat > /etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.icmp_echo_ignore_all = 1
EOF
sysctl -p /etc/sysctl.d/99-vpn-tuning.conf
tc qdisc replace dev ens3 root fq
```

`Module bbr not found` при наличии `tcp_bbr.ko` — это протухший `modules.dep`, а не
отсутствующий модуль. `depmod -a` лечит.

## UFW для VPN-сервера

Порядок: сначала правила, потом enable — иначе рискуешь закрыть SSH.

```bash
ufw default deny incoming; ufw default allow outgoing
for p in 22 80 443 2096 8443 29190; do ufw allow $p/tcp; done
ufw allow 39000/udp
ufw --force enable; ufw status verbose
systemctl start ufw        # привести юнит в active после reset/enable
```

- 80/tcp держать открытым: нужен для HTTP-01 при продлении сертификата.
- Docker-опубликованные порты UFW не закрывает (см. грабли в SKILL.md).
- Порт панели в интернет — осознанное решение пользователя: спроси, не закрывай сам.
  Если оставляешь — предложи 2FA (Настройки → Telegram-бот) и сильный пароль.

## SSH и fail2ban

```bash
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sshd -T | grep -E 'passwordauthentication|permitrootlogin'
apt install -y fail2ban && systemctl enable --now fail2ban
fail2ban-client status sshd
```

Ключи: `/root/.ssh/authorized_keys` может содержать старые ключи — спроси владельца,
прежде чем чистить.

## Что докладывать

Разделяй отчёт на: сделано и чем проверено / что должен сделать пользователь на
устройствах / что осталось и какие риски. Не смешивай «заявлено» и «проверено».
