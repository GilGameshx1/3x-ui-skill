#!/usr/bin/env bash
# Состояние сервера по факту, без изменений: что реально сделано, а что только
# записано в чьём-то гайде. Заменяет «прогон шагов на глаз».
#
#   scripts/state_check.sh              таблица PASS/WARN/FAIL
#   scripts/state_check.sh --json       то же в JSON (для мониторинга)
#   scripts/state_check.sh --strict     код возврата 1, если есть FAIL
#   scripts/state_check.sh --quick      без сетевых проверок (панель, подписка)
#
# Скрипт только читает: файлы, БД, systemd, sysctl, сокеты. Ничего не меняет и
# секретов не печатает.
set -uo pipefail

DB=${XUI_DB:-/etc/x-ui/x-ui.db}
BACKUP_DIR=${BACKUP_DIR:-/root/x-ui-backups}
JSON=0
STRICT=0
QUICK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON=1 ;;
        --strict) STRICT=1 ;;
        --quick)  QUICK=1 ;;
        --db)     DB=${2:?нужен путь}; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 64 ;;
    esac
    shift
done

ROWS=()
PASS_N=0
WARN_N=0
FAIL_N=0

row() { # row STATUS ID DETAIL
    local st=$1 id=$2 detail=${3:-}
    case "$st" in
        PASS) PASS_N=$((PASS_N + 1)) ;;
        WARN) WARN_N=$((WARN_N + 1)) ;;
        FAIL) FAIL_N=$((FAIL_N + 1)) ;;
    esac
    ROWS+=("$st|$id|$detail")
    if [[ $JSON -eq 0 ]]; then
        printf '%-4s %-26s %s\n' "$st" "$id" "$detail"
    fi
}

ok()   { row PASS "$1" "${2:-}"; }
warn() { row WARN "$1" "${2:-}"; }
bad()  { row FAIL "$1" "${2:-}"; }

have() { command -v "$1" >/dev/null 2>&1; }

setting() { # setting KEY
    [[ -f $DB ]] && have sqlite3 || return 0
    sqlite3 "$DB" "select value from settings where key='$1';" 2>/dev/null
}

# ---------------------------------------------------------------- база и ОС

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok os "${PRETTY_NAME:-Linux} $(uname -r)"
else
    warn os "не читается /etc/os-release"
fi

[[ $EUID -eq 0 ]] || warn root "запущено не от root — часть проверок не видна"

if [[ ! -f $DB ]]; then
    bad panel.db "нет $DB — панель не установлена"
elif ! have sqlite3; then
    warn panel.db "нет sqlite3, БД не прочитать"
else
    integrity=$(sqlite3 "$DB" "pragma integrity_check;" 2>/dev/null | head -1)
    [[ $integrity == ok ]] && ok panel.db "integrity ok" \
        || bad panel.db "integrity_check: ${integrity:-нет ответа}"
fi

if systemctl is-active --quiet x-ui 2>/dev/null; then
    ok panel.service "x-ui active"
else
    bad panel.service "x-ui не запущен"
fi

PANEL_PORT=$(setting webPort)
PANEL_PATH=$(setting webBasePath)
[[ -n $PANEL_PORT ]] && ok panel.port "webPort=$PANEL_PORT base=${PANEL_PATH:-/}" \
    || warn panel.port "webPort не найден в settings"

if [[ $QUICK -eq 0 && -n $PANEL_PORT ]]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
        "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH:-}/" 2>/dev/null)
    case "$code" in
        200|301|302|303) ok panel.http "HTTP $code на 127.0.0.1:$PANEL_PORT" ;;
        000|"")      bad panel.http "панель не отвечает на 127.0.0.1:$PANEL_PORT" ;;
        *)           warn panel.http "HTTP $code на 127.0.0.1:$PANEL_PORT" ;;
    esac

    # Наружу порт панели торчать не должен: только localhost и SSH-туннель.
    if have ss && ss -ltnH 2>/dev/null | grep -qE "[:.]${PANEL_PORT}[[:space:]]"; then
        if ss -ltnH 2>/dev/null | grep -E "[:.]${PANEL_PORT}[[:space:]]" \
             | grep -vqE '127\.0\.0\.1|\[::1\]'; then
            bad panel.exposure "порт панели слушает не только localhost"
        else
            ok panel.exposure "панель только на localhost"
        fi
    fi
fi

# ---------------------------------------------------------------- входящие

if [[ -f $DB ]] && have sqlite3; then
    while IFS='|' read -r id remark port proto enable; do
        [[ -n ${id:-} ]] || continue
        key="inbound.${id}"
        if [[ $enable == 1 ]]; then
            ok "$key" "id=$id ${remark:-?} ${proto:-?}/$port включён"
        else
            warn "$key" "id=$id ${remark:-?} выключен в панели"
        fi

        if [[ $QUICK -eq 0 ]] && have ss; then
            if ss -ltnH 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
                ok "$key.port" "слушает $port/tcp"
            else
                bad "$key.port" "порт $port не слушается"
            fi
        fi

        stream=$(sqlite3 "$DB" "select stream_settings from inbounds where id=$id;" 2>/dev/null)
        if [[ -n $stream ]]; then
            parsed=$(printf '%s' "$stream" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("? |? |? |? |?"); raise SystemExit
rs = s.get("realitySettings") or {}
inner = rs.get("settings") or {}
print("%s|%s|%s|%s|%s" % (
    s.get("security") or "none",
    rs.get("privateKey") or inner.get("privateKey") or "",
    inner.get("publicKey") or rs.get("publicKey") or "",
    rs.get("serverName") or inner.get("serverName")
    or (rs.get("serverNames") or [""])[0] or "",
    rs.get("shortIds") or []))
' 2>/dev/null)
            IFS='|' read -r sec priv pub sni _sids <<<"$parsed"
            if [[ $sec == reality ]]; then
                if [[ -z $priv ]]; then
                    bad "$key.reality" "нет privateKey в streamSettings"
                elif [[ -z $pub ]]; then
                    warn "$key.reality" "нет publicKey — ссылку собирать через x25519 -i"
                elif have python3 && [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
                    derived=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519 -i "$priv" 2>/dev/null \
                        | awk -F': *' 'tolower($1) ~ /^(password|publickey)$/ {print $2; exit}')
                    if [[ $derived == "$pub" ]]; then
                        ok "$key.reality" "ключи Reality сходятся, SNI ${sni:-?}"
                    else
                        bad "$key.reality" "publicKey не выводится из privateKey"
                    fi
                else
                    warn "$key.reality" "бинарь xray не найден, пару не проверить"
                fi
                [[ -n $sni ]] || warn "$key.sni" "пустой serverName"
            else
                ok "$key.security" "security=$sec"
            fi
        fi

        if [[ -n ${port:-} ]]; then
            clients=$(sqlite3 "$DB" "select settings from inbounds where id=$id;" 2>/dev/null \
                | python3 -c '
import json, sys, time
try:
    s = json.load(sys.stdin)
except Exception:
    print("? ? ?"); raise SystemExit
cl = s.get("clients") or []
now = int(time.time() * 1000)
expired = sum(1 for c in cl if c.get("expiryTime") and c["expiryTime"] < now)
noflow = sum(1 for c in cl if not c.get("flow"))
print("%d %d %d" % (len(cl), expired, noflow))
' 2>/dev/null)
            read -r n exp noflow <<<"$clients"
            if [[ -n ${n:-} && $n != "?" ]]; then
                detail="$n клиентов"
                [[ $exp -gt 0 ]] && detail="$detail, просрочено $exp"
                [[ $noflow -gt 0 ]] && detail="$detail, без flow $noflow"
                if [[ $exp -gt 0 ]]; then warn "$key.clients" "$detail"
                elif [[ $noflow -gt 0 ]]; then warn "$key.clients" "$detail"
                else ok "$key.clients" "$detail"; fi
            fi
        fi
    done < <(sqlite3 -separator '|' "$DB" \
        "select id,remark,port,protocol,enable from inbounds order by id;" 2>/dev/null)
fi

# ---------------------------------------------------------------- подписка

SUB_ENABLE=$(setting subEnable)
SUB_PORT=$(setting subPort)
SUB_PATH=$(setting subPath)
if [[ ${SUB_ENABLE,,} == true ]]; then
    ok sub.enabled "subPort=${SUB_PORT:-?} path=${SUB_PATH:-/}"
    if [[ $QUICK -eq 0 && -n $SUB_PORT ]]; then
        probe=$(sqlite3 "$DB" "select settings from inbounds;" 2>/dev/null \
            | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        for c in (json.loads(line).get("clients") or []):
            if c.get("subId"):
                print(c["subId"]); raise SystemExit
    except Exception:
        continue
' 2>/dev/null)
        if [[ -n $probe ]]; then
            scheme=https
            [[ -n $(setting subCertFile) && -n $(setting subKeyFile) ]] || scheme=http
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
                "${scheme}://127.0.0.1:${SUB_PORT}${SUB_PATH}${probe}" 2>/dev/null)
            [[ $code == 200 ]] && ok sub.http "HTTP 200 для subId" \
                || bad sub.http "подписка отдаёт HTTP ${code:-000}"
        else
            warn sub.http "ни у одного клиента нет subId — проверка пропущена"
        fi
    fi
else
    warn sub.enabled "подписка выключена (scripts/sub_setup.sh)"
fi

# ---------------------------------------------------------------- SSH / сеть

if have sshd; then
    eff=$(sshd -T 2>/dev/null)
    grep -qi '^permitrootlogin yes' <<<"$eff" && bad ssh.rootlogin "PermitRootLogin yes" \
        || ok ssh.rootlogin "root по паролю/ключу закрыт"
    grep -qi '^passwordauthentication yes' <<<"$eff" \
        && bad ssh.passwordauth "PasswordAuthentication yes" \
        || ok ssh.passwordauth "парольный вход закрыт"
else
    warn ssh "sshd не найден"
fi

if have ufw; then
    if ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; then
        ok ufw.active "ufw active"
        rules=$(ufw status 2>/dev/null)
        for p in 22 443; do
            grep -qE "^${p}(/tcp)? +(ALLOW|allow)" <<<"$rules" \
                && ok "ufw.${p}" "порт $p разрешён" \
                || warn "ufw.${p}" "нет правила ALLOW для $p"
        done
        grep -qi 'Status: active' <<<"$rules" || true
        grep -qiE '^IPV6=(yes|on)' /etc/default/ufw 2>/dev/null \
            && ok ufw.ipv6 "IPv6-правила включены" \
            || warn ufw.ipv6 "IPV6=no в /etc/default/ufw"
    else
        bad ufw.active "ufw не активен"
    fi
else
    warn ufw.active "ufw не установлен"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok fail2ban "active"
else
    warn fail2ban "fail2ban не запущен"
fi

if have sysctl; then
    [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]] \
        && ok sysctl.bbr "tcp_congestion_control=bbr" \
        || warn sysctl.bbr "не bbr"
    [[ $(sysctl -n net.core.default_qdisc 2>/dev/null) == fq ]] \
        && ok sysctl.qdisc "qdisc=fq" || warn sysctl.qdisc "не fq"
    [[ $(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null) == 1 ]] \
        && ok sysctl.icmp "ICMP echo выключен" \
        || warn sysctl.icmp "сервер отвечает на ping"
fi

# ---------------------------------------------------------------- сертификаты

certs=0
for key in webCertFile subCertFile; do
    f=$(setting "$key")
    [[ -n $f ]] || continue
    certs=$((certs + 1))
    if [[ ! -f $f ]]; then
        bad "cert.${key}" "файла нет: $f"
    elif openssl x509 -in "$f" -noout -checkend 259200 >/dev/null 2>&1; then
        end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)
        ok "cert.${key}" "жив до $end"
    elif openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
        end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)
        warn "cert.${key}" "истекает раньше 3 дней: $end"
    else
        bad "cert.${key}" "просрочен"
    fi
done
[[ $certs -eq 0 ]] && warn cert "сертификаты не заданы (панель на self-signed)"

# ---------------------------------------------------------------- бэкапы, таймеры

newest=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.gz' -o -name '*.age' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [[ -n $newest ]]; then
    age_h=$(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))
    if (( age_h <= 48 )); then
        ok backup.fresh "свежий бэкап: $(basename "$newest"), ${age_h}ч назад"
    else
        warn backup.fresh "последний бэкап ${age_h}ч назад: $(basename "$newest")"
    fi
    [[ $newest == *.age ]] && ok backup.encrypted "бэкап зашифрован age" \
        || warn backup.encrypted "бэкап не зашифрован (references/backup-offsite.md)"
else
    warn backup.fresh "в $BACKUP_DIR нет бэкапов"
fi

for t in 3x-ui-backup.timer 3xui-watchdog.timer; do
    if systemctl list-timers --all --no-legend 2>/dev/null | grep -q "$t"; then
        ok "timer.${t}" "$(systemctl is-active "$t" 2>/dev/null)"
    else
        warn "timer.${t}" "не установлен"
    fi
done

# ---------------------------------------------------------------- IPv6, диск

if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    dis=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    if [[ $dis == 1 ]]; then
        ok ipv6 "IPv6 выключен на хосте"
    else
        v6addr=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ')
        if [[ ${v6addr:-0} -eq 0 ]]; then
            ok ipv6 "IPv6 включён в ядре, глобальных адресов нет"
        else
            warn ipv6 "global IPv6 есть ($v6addr) — проверьте утечку: references/ipv6.md"
        fi
    fi
else
    warn ipv6 "нет /proc/sys/net/ipv6 — IPv6 не скомпилирован"
fi

use=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
if [[ -n ${use:-} ]]; then
    if (( use >= 90 )); then bad disk "корень занят на ${use}%"
    elif (( use >= 80 )); then warn disk "корень занят на ${use}%"
    else ok disk "корень занят на ${use}%"; fi
fi

# ---------------------------------------------------------------- xray config

if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
    if /usr/local/x-ui/bin/xray-linux-amd64 run -test \
        -c /usr/local/x-ui/bin/config.json >/dev/null 2>&1; then
        ok xray.config "config.json проходит xray -test"
    else
        bad xray.config "config.json не проходит xray -test"
    fi
fi

# ---------------------------------------------------------------- вывод

if [[ $JSON -eq 1 ]]; then
    printf '%s\n' "${ROWS[@]}" | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    st, ident, detail = (line.rstrip("\n").split("|", 2) + ["", ""])[:3]
    if st:
        rows.append({"status": st, "check": ident, "detail": detail})
counts = {}
for r in rows:
    counts[r["status"]] = counts.get(r["status"], 0) + 1
print(json.dumps({"checks": rows, "summary": counts}, ensure_ascii=False, indent=2))
'
else
    printf '\nPASS %d   WARN %d   FAIL %d\n' "$PASS_N" "$WARN_N" "$FAIL_N"
fi

if [[ $STRICT -eq 1 && $FAIL_N -gt 0 ]]; then
    exit 1
fi
exit 0
