#!/bin/bash
# Read-only инвентаризация VPN-сервера. Ничего не меняет.
set -u

sec() { printf '\n===== %s =====\n' "$1"; }

sec "OS / KERNEL / UPTIME"
head -3 /etc/os-release; uname -r; uptime

sec "IPv4 / ROUTES"
ip -4 addr show | grep -E 'inet |^[0-9]+:'
ip route

sec "EXIT IP (host)"
curl -s -4 --max-time 8 https://ifconfig.me; echo

sec "LISTENING PORTS"
ss -tulpn | grep -vE '127\.0\.0\.53|\[::1\]'

sec "SERVICES"
systemctl list-units --type=service --all 2>/dev/null \
  | grep -iE 'x-ui|xray|wireguard|wg-quick|openvpn|sing-box|hysteria|v2ray|fail2ban|docker'

sec "DOCKER"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
  || echo 'docker отсутствует'

sec "FIREWALL"
ufw status verbose 2>/dev/null || echo 'ufw не установлен'

sec "SSH"
sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers)'
ls -la /root/.ssh 2>/dev/null | head -5

sec "SYSCTL"
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.icmp_echo_ignore_all 2>/dev/null

sec "CERTIFICATES"
xui_db=/etc/x-ui/x-ui.db
if [ -f "$xui_db" ] && command -v sqlite3 >/dev/null; then
  for f in $(sqlite3 "$xui_db" "select value from settings where key in ('webCertFile','subCertFile');" 2>/dev/null | sort -u); do
    if [ -f "$f" ]; then
      echo "$f:"
      openssl x509 -in "$f" -noout -subject -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'
    fi
  done
fi

sec "X-UI INBOUNDS"
if [ -f "$xui_db" ] && command -v sqlite3 >/dev/null; then
  sqlite3 "$xui_db" "select id,remark,enable,port,protocol from inbounds;" 2>/dev/null
  sqlite3 "$xui_db" "select email,enable,expiry_time from client_traffics;" 2>/dev/null
fi

sec "RESOURCES"
df -h /; free -h
du -sh /var/log /root /var/lib/docker 2>/dev/null

sec "UPDATES"
apt list --upgradable 2>/dev/null | tail -n +2 | head -10

sec "LOGINS"
last -n 6 2>/dev/null
grep -c 'Failed password' /var/log/auth.log 2>/dev/null | sed 's/^/failed ssh password attempts: /'
