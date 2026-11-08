#!/usr/bin/env bash
# Восстановление БД 3x-ui из бэкапа: .db, .db.gz, .db.age.
#
#   scripts/restore-db.sh                       показать копии и спросить файл
#   scripts/restore-db.sh /root/x-ui-backups/x-ui-20260101-041700.db.gz
#   scripts/restore-db.sh --yes <файл>          без интерактивного подтверждения
#   scripts/restore-db.sh --age-identity /root/age.key <файл.age>
#
# Порядок: копия текущей БД → стоп панели → распаковка/расшифровка во временный
# файл → integrity_check → подмена → старт → проверка. Если что-то не сошлось,
# текущая БД возвращается на место.
set -euo pipefail

DB=${XUI_DB:-/etc/x-ui/x-ui.db}
DIR=${BACKUP_DIR:-/root/x-ui-backups}
AGE_ID=${AGE_IDENTITY:-/root/age.key}
ASSUME_YES=0
BACKUP_FILE=""

err() { printf 'ОШИБКА: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)           DB=${2:?нужен путь}; shift ;;
        --dir)          DIR=${2:?нужен путь}; shift ;;
        --age-identity) AGE_ID=${2:?нужен путь}; shift ;;
        --yes|-y)       ASSUME_YES=1 ;;
        -h|--help)      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             err "неизвестный флаг: $1"; exit 64 ;;
        *)              BACKUP_FILE=$1 ;;
    esac
    shift
done

command -v sqlite3 >/dev/null || { err "нет sqlite3"; exit 1; }

if [[ -z $BACKUP_FILE ]]; then
    [[ -d $DIR ]] || { err "нет каталога с бэкапами: $DIR"; exit 1; }
    mapfile -t list < <(find "$DIR" -maxdepth 1 -type f \
        \( -name 'x-ui-*.db*' -o -name 'x-ui.db.backup.*' \) | sort -r)
    ((${#list[@]})) || { err "в $DIR нет бэкапов"; exit 1; }
    printf '%s\n' "${list[@]}"
    read -r -p "Файл для восстановления: " BACKUP_FILE
    [[ $BACKUP_FILE == /* ]] || BACKUP_FILE="$DIR/$BACKUP_FILE"
fi

[[ -f $BACKUP_FILE ]] || { err "нет файла: $BACKUP_FILE"; exit 1; }

echo "Восстановление: $BACKUP_FILE"
echo "Цель:           $DB"

if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Текущая БД будет заменена. Введите YES: " confirm
    [[ $confirm == YES ]] || { echo "Отменено."; exit 0; }
fi

TMP=$(mktemp)
CURRENT=""
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# 1. Развернуть бэкап во временный файл (до остановки панели).
case "$BACKUP_FILE" in
    *.age)
        command -v age >/dev/null || { err "нужен age для .age-бэкапа"; exit 1; }
        [[ -r $AGE_ID ]] || { err "нет ключа age: $AGE_ID"; exit 1; }
        age -d -i "$AGE_ID" "$BACKUP_FILE" > "$TMP" ;;
    *.gz)
        gzip -dc "$BACKUP_FILE" > "$TMP" ;;
    *.bz2)
        bzip2 -dc "$BACKUP_FILE" > "$TMP" ;;
    *)
        cp "$BACKUP_FILE" "$TMP" ;;
esac

integrity=$(sqlite3 "$TMP" "pragma integrity_check;" 2>/dev/null | head -1 || true)
[[ $integrity == ok ]] || { err "бэкап не прошёл integrity_check: $integrity"; exit 1; }
echo "  integrity ok (до остановки панели)"
[[ $(sqlite3 "$TMP" "select count(*) from inbounds;" 2>/dev/null) =~ ^[0-9]+$ ]] \
    || { err "в файле нет таблицы inbounds — это не БД 3x-ui"; exit 1; }

# 2. Сохранить текущую БД (WAL-safe, иначе последние клиенты теряются).
if [[ -f $DB ]]; then
    CURRENT="$DB.before-restore.$(date +%Y%m%d-%H%M%S)"
    sqlite3 "$DB" ".backup '$CURRENT'"
    chmod 600 "$CURRENT"
    echo "  текущая БД: $CURRENT"
fi

# 3. Подмена под остановленной панелью.
x-ui stop >/dev/null 2>&1 || true
cp "$TMP" "$DB"
chown --reference="$CURRENT" "$DB" 2>/dev/null || true
rm -f "$DB-wal" "$DB-shm"
integrity=$(sqlite3 "$DB" "pragma integrity_check;" 2>/dev/null | head -1 || true)
if [[ $integrity != ok ]]; then
    [[ -n $CURRENT ]] && cp "$CURRENT" "$DB"
    x-ui start >/dev/null 2>&1 || true
    err "после подмены integrity_check: $integrity — вернул прежнюю БД"
    exit 1
fi
x-ui start >/dev/null 2>&1 || true

# 4. Проверка по факту: панель поднялась и отвечает.
sleep 3
port=$(sqlite3 "$DB" "select value from settings where key='webPort';" 2>/dev/null)
base=$(sqlite3 "$DB" "select value from settings where key='webBasePath';" 2>/dev/null)
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:${port}${base:-}/" 2>/dev/null || true)
if [[ $code == 000 || -z $code ]]; then
    err "панель не отвечает после восстановления (порт ${port:-?}) — смотрите journalctl -u x-ui"
    exit 1
fi

echo "PASS: БД восстановлена, панель отвечает (HTTP $code)"
[[ -n $CURRENT ]] && echo "Откат при необходимости: cp '$CURRENT' '$DB' && x-ui restart"
