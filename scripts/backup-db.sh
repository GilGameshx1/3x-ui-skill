#!/usr/bin/env bash
# Бэкап БД 3x-ui: целостная копия, шифрование age, выгрузка наружу через rclone.
#
#   scripts/backup-db.sh                        локально в /root/x-ui-backups
#   scripts/backup-db.sh --offsite              + rclone copy в удалённое хранилище
#   scripts/backup-db.sh --keep 14 --offsite
#   scripts/backup-db.sh --dry-run              показать план, ничего не писать
#
# Копия делается через `sqlite3 .backup`, а не cp: в WAL-режиме cp даёт битую БД.
# Бэкап на том же диске не спасает при потере VPS — для этого --offsite
# (настройка: references/backup-offsite.md).
set -euo pipefail

DB=${XUI_DB:-/etc/x-ui/x-ui.db}
DIR=${BACKUP_DIR:-/root/x-ui-backups}
KEEP=10
OFFSITE=0
DRY=0
QUIET=0
RCLONE_REMOTE=${RCLONE_REMOTE:-}
AGE_RECIPIENT=${AGE_RECIPIENT:-}
ENV_FILE=${BACKUP_ENV_FILE:-/etc/3x-ui-backup.env}

say() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }
err() { printf 'ОШИБКА: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)            DB=${2:?нужен путь}; shift ;;
        --dir)           DIR=${2:?нужен путь}; shift ;;
        --keep)          KEEP=${2:?нужно число}; shift ;;
        --offsite)       OFFSITE=1 ;;
        --dry-run)       DRY=1 ;;
        --quiet)         QUIET=1 ;;
        --rclone-remote) RCLONE_REMOTE=${2-}; shift ;;
        --age-recipient) AGE_RECIPIENT=${2:?нужен публичный ключ age}; shift ;;
        --env-file)      ENV_FILE=${2:?нужен путь}; shift ;;
        -h|--help)       sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "неизвестный аргумент: $1"; exit 64 ;;
    esac
    shift
done

# Настройки выгрузки — отдельным файлом с правами 600, не в репозитории.
if [[ -r $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

# Проверки «до работы»: иначе локальная копия создастся, а выгрузка молча не будет.
if [[ $OFFSITE -eq 1 && -z $RCLONE_REMOTE ]]; then
    err "--offsite требует RCLONE_REMOTE (env-файл $ENV_FILE или --rclone-remote)"
    exit 1
fi

command -v sqlite3 >/dev/null || { err "нет sqlite3"; exit 1; }
[[ -f $DB ]] || { err "нет БД: $DB"; exit 1; }
[[ $KEEP =~ ^[0-9]+$ ]] || { err "--keep должен быть числом"; exit 1; }

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BASE="$DIR/x-ui-$TIMESTAMP.db"

say "Бэкап $DB → $DIR"
if [[ $DRY -eq 1 ]]; then
    say "[dry-run] sqlite3 .backup → $BASE(.gz|.age), храню последние $KEEP"
    [[ $OFFSITE -eq 1 ]] && say "[dry-run] rclone copy → ${RCLONE_REMOTE:-<не задан>}"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
TMP=$(mktemp "$DIR/.backup.XXXXXX.db")
cleanup() { rm -f "$TMP" "$TMP.gz" "$TMP.age"; }
trap cleanup EXIT

# 1. Согласованная копия (WAL-safe), затем проверка целостности уже копии.
sqlite3 "$DB" ".backup '$TMP'"
integrity=$(sqlite3 "$TMP" "pragma integrity_check;" | head -1)
[[ $integrity == ok ]] || { err "копия не прошла integrity_check: $integrity"; exit 1; }
say "  integrity ok"

# 2. Шифрование (если задан получатель) и сжатие.
if [[ -n $AGE_RECIPIENT ]]; then
    command -v age >/dev/null || { err "задан AGE_RECIPIENT, но age не установлен"; exit 1; }
    age -r "$AGE_RECIPIENT" -o "$TMP.age" "$TMP"
    mv "$TMP.age" "$BASE.age"
    chmod 600 "$BASE.age"
    BACKUP_FILE="$BASE.age"
    say "  зашифровано age"
else
    gzip -9 "$TMP"
    mv "$TMP.gz" "$BASE.gz"
    chmod 600 "$BASE.gz"
    BACKUP_FILE="$BASE.gz"
    say "  сжато gzip; шифрование выключено (см. references/backup-offsite.md)"
fi

say "  файл: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# 3. Выгрузка наружу: без неё бэкап умирает вместе с VPS.
if [[ $OFFSITE -eq 1 ]]; then
    command -v rclone >/dev/null || { err "нет rclone"; exit 1; }
    rclone copy --no-traverse "$BACKUP_FILE" "$RCLONE_REMOTE" \
        || { err "rclone copy не прошёл"; exit 1; }
    name=$(basename "$BACKUP_FILE")
    # Проверка по факту: файл реально виден в удалённом хранилище.
    if rclone lsf "$RCLONE_REMOTE" --files-only | grep -qx "$name"; then
        say "  выгружено: $RCLONE_REMOTE/$name"
    else
        err "после rclone copy файла $name нет в $RCLONE_REMOTE"
        exit 1
    fi
    # Ротация на удалённой стороне: имена сортируются по времени.
    mapfile -t remote_old < <(rclone lsf "$RCLONE_REMOTE" --files-only \
        | grep -E '^x-ui-[0-9]{8}-[0-9]{6}\.db\.(gz|age)$' | sort | head -n "-$KEEP")
    for f in "${remote_old[@]:-}"; do
        [[ -n $f ]] && rclone deletefile "$RCLONE_REMOTE/$f" || true
    done
fi

# 4. Ротация локальных копий.
mapfile -t old < <(find "$DIR" -maxdepth 1 -type f -name 'x-ui-*.db.*' \
    -printf '%T@ %p\n' | sort -rn | awk -v k="$KEEP" 'NR>k {print $2}')
if ((${#old[@]})); then
    rm -f -- "${old[@]}"
    say "  удалено старых копий: ${#old[@]}"
fi

say "Готово: $(basename "$BACKUP_FILE")"
