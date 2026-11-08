#!/bin/bash
# Read-only инвентаризация VPN-сервера. Ничего не меняет.
# bash server_audit.sh [domain]   # чей AAAA смотреть (по умолчанию hostname -f)
# AUDIT_DOMAIN=<domain> bash server_audit.sh   # то же через переменную
set -u

sec() { printf '\n===== %s =====\n' "$1"; }

sec "OS / KERNEL / UPTIME"
head -3 /etc/os-release; uname -r; uptime

sec "IPv4 / ROUTES"
ip -4 addr show | grep -E 'inet |^[0-9]+:'
ip route

sec "IPv6 / ROUTES"
if [ -d /proc/sys/net/ipv6 ]; then
  ip -6 addr show | grep -E 'inet6 |^[0-9]+:'
  echo '--- default route ---'
  v6_default=$(ip -6 route show default 2>/dev/null)
  printf '%s\n' "${v6_default:-нет default-маршрута IPv6}"
  echo '--- sysctl disable_ipv6 ---'
  sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 2>/dev/null
  echo '--- exit IPv6 ---'
  v6_exit=$(curl -6 -s --max-time 8 https://ipv6.icanhazip.com 2>/dev/null)
  printf '%s\n' "${v6_exit:-нет (IPv6-выход недоступен)}"
  echo '--- AAAA ---'
  audit_domain="${AUDIT_DOMAIN:-${1:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}}"
  if command -v dig >/dev/null 2>&1; then
    aaaa=$(dig +short AAAA "$audit_domain" 2>/dev/null)
  else
    aaaa=$(getent ahostsv6 "$audit_domain" 2>/dev/null | awk '{print $1}' | sort -u)
  fi
  if [ -n "$aaaa" ]; then
    printf '%s: %s\n' "$audit_domain" "$(printf '%s' "$aaaa" | tr '\n' ' ')"
  else
    printf '%s: нет AAAA\n' "$audit_domain"
  fi
  echo '--- listening [::] ---'
  v6_listen=$(ss -6 -H -tulpn 2>/dev/null | grep -v '\[::1\]')
  printf '%s\n' "${v6_listen:-нет IPv6-слушателей}"
  echo '--- ufw IPv6 ---'
  if grep -qE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
    echo 'ufw IPv6: yes (правила ufw применяются и к v6)'
  elif grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; then
    echo 'ufw IPv6: no (v6 фильтруется только внешним firewall)'
  else
    echo 'ufw IPv6: не задан в /etc/default/ufw (по умолчанию yes)'
  fi
else
  echo 'IPv6 выключен в ядре (/proc/sys/net/ipv6 отсутствует)'
fi

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
