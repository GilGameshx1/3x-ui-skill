#!/usr/bin/env bash
# Сторож VPN: панель жива, порт слушается, туннель реально выпускает трафик.
# Молча работает из таймера, при поломке пишет в Telegram и ставит failed.
#
#   scripts/watchdog.sh            один прогон (systemd делает это каждые 5 минут)
#   scripts/watchdog.sh --verbose  печатать результат в stdout
#
# Настройки — /etc/3x-ui-watchdog.env (chmod 600), см. references/watchdog.md.
# Пароль панели не нужен: проверяется сокет и, если заданы креды клиента,
# сквозной тест verify_vless.py.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${WATCHDOG_ENV:-/etc/3x-ui-watchdog.env}
DB=${XUI_DB:-/etc/x-ui/x-ui.db}
STATE_FILE=${STATE_FILE:-/var/lib/3x-ui-watchdog/state}
ALERT_EVERY_MIN=${ALERT_EVERY_MIN:-30}
VERBOSE=0
[[ ${1:-} == --verbose ]] && VERBOSE=1

# Значения по умолчанию; файл настроек их переопределяет.
CHECK_PORT=""
CHECK_UUID=""
CHECK_PBK=""
CHECK_SNI=""
CHECK_SID=""
CHECK_FLOW="xtls-rprx-vision"
EXPECT_IP=""
PANEL_PORT=""
PANEL_PATH=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

if [[ -r $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
else
    echo "ПРЕДУПРЕЖДЕНИЕ: нет $ENV_FILE — проверки ограничены панелью и портом" >&2
fi

say() { [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$*"; return 0; }
have() { command -v "$1" >/dev/null 2>&1; }

notify() { # notify TEXT
    [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]] || return 0
    have curl || return 0
    curl -fsS --max-time 15 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
}

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
last_status="unknown"
last_alert=0
if [[ -r $STATE_FILE ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE" || true
fi

problems=()

# 1. Панель
if systemctl is-active --quiet x-ui 2>/dev/null; then
    say "x-ui: active"
else
    problems+=("панель x-ui не запущена")
fi

# 2. Порт входящего: слушается ли сокет
if [[ -z $CHECK_PORT ]] && [[ -f $DB ]] && have sqlite3; then
    CHECK_PORT=$(sqlite3 "$DB" "select port from inbounds where enable=1 order by id limit 1;" 2>/dev/null)
fi
if [[ -n ${CHECK_PORT:-} ]]; then
    if have ss && ! ss -ltnH 2>/dev/null | grep -qE "[:.]${CHECK_PORT}[[:space:]]"; then
        problems+=("порт ${CHECK_PORT}/tcp не слушается")
    else
        say "порт ${CHECK_PORT}: слушается"
    fi
fi

# 3. Панель отвечает по HTTP
if [[ -z ${PANEL_PORT:-} && -f $DB ]] && have sqlite3; then
    PANEL_PORT=$(sqlite3 "$DB" "select value from settings where key='webPort';" 2>/dev/null)
fi
if [[ -z ${PANEL_PATH:-} && -f $DB ]] && have sqlite3; then
    PANEL_PATH=$(sqlite3 "$DB" "select value from settings where key='webBasePath';" 2>/dev/null)
fi
if [[ -n ${PANEL_PORT:-} ]] && have curl; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
        "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH:-}/" 2>/dev/null)
    case $code in
        000|"") problems+=("панель не отвечает на 127.0.0.1:${PANEL_PORT}${PANEL_PATH:-}/") ;;
        *)      say "панель: HTTP $code" ;;
    esac
fi

# 4. Сквозная проверка туннеля (нужны креды клиента в env-файле)
if [[ -n ${CHECK_UUID:-} && -n ${CHECK_PBK:-} && -n ${CHECK_SNI:-} && -n ${CHECK_PORT:-} ]]; then
    args=(--ip 127.0.0.1 --port "$CHECK_PORT" --uuid "$CHECK_UUID"
          --pbk "$CHECK_PBK" --sni "$CHECK_SNI" --flow "$CHECK_FLOW")
    [[ -n ${CHECK_SID:-} ]] && args+=(--sid "$CHECK_SID")
    [[ -n ${EXPECT_IP:-} ]] && args+=(--expect "$EXPECT_IP")
    out=$(python3 "$HERE/verify_vless.py" "${args[@]}" 2>&1)
    rc=$?
    say "туннель: $out"
    [[ $rc -ne 0 ]] && problems+=("сквозная проверка не прошла: ${out}")
else
    say "туннель: креды клиента не заданы — пропущено"
fi

# 5. Решение: алерт с антидребезгом, отбой при восстановлении
now=$(date +%s)
if ((${#problems[@]})); then
    detail=$(printf '• %s\n' "${problems[@]}")
    if [[ $last_status != fail ]] || (( now - last_alert > ALERT_EVERY_MIN * 60 )); then
        notify "🔴 VPN на $(hostname -s): проверка не прошла
${detail}"
        last_alert=$now
    fi
    printf 'STATUS=fail\nlast_alert=%s\n' "$last_alert" >"$STATE_FILE"
    printf 'FAIL: %s\n' "${problems[*]}" >&2
    exit 1
fi

if [[ $last_status == fail ]]; then
    notify "🟢 VPN на $(hostname -s): снова работает, проверка прошла"
fi
printf 'STATUS=ok\nlast_alert=0\n' >"$STATE_FILE"
say "OK"
exit 0
