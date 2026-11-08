#!/usr/bin/env bats
# Скрипты состояния, бэкапа и стража репозитория — на фикстурах, без живого VPN.

load helpers

setup() { setup_fixture; }
teardown() { teardown_fixture; }

@test "state_check: JSON валиден и содержит обязательные проверки" {
    run bash "$REPO_ROOT/scripts/state_check.sh" --json --quick --db "$XUI_DB"
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ids={c["check"] for c in d["checks"]}
assert "panel.db" in ids, ids
assert "sub.enabled" in ids, ids
assert "disk" in ids, ids
assert set(d["summary"]) <= {"PASS","WARN","FAIL"}
'
}

@test "state_check: нет БД — это FAIL, а не падение" {
    run bash "$REPO_ROOT/scripts/state_check.sh" --json --quick --db "$TEST_DIR/nope.db"
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=[c for c in d["checks"] if c["check"]=="panel.db"][0]
assert row["status"]=="FAIL", row
'
}

@test "state_check: --strict возвращает 1 при FAIL" {
    run bash "$REPO_ROOT/scripts/state_check.sh" --quick --strict --db "$TEST_DIR/nope.db"
    [ "$status" -eq 1 ]
}

@test "state_check: секретов в выводе нет" {
    run bash "$REPO_ROOT/scripts/state_check.sh" --json --quick --db "$XUI_DB"
    [ "$status" -eq 0 ]
    [[ $output != *"11111111-2222"* ]]
    [[ $output != *"<PRIVATE_KEY>"* ]]
}

@test "backup: dry-run ничего не создаёт" {
    run bash "$REPO_ROOT/scripts/backup-db.sh" --db "$XUI_DB" --dir "$TEST_DIR/bk" --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"[dry-run]"* ]]
    [ ! -d "$TEST_DIR/bk" ]
}

@test "backup: создаёт сжатую копию и проходит integrity" {
    run bash "$REPO_ROOT/scripts/backup-db.sh" --db "$XUI_DB" --dir "$TEST_DIR/bk" --keep 2
    [ "$status" -eq 0 ]
    ls "$TEST_DIR/bk"/x-ui-*.db.gz >/dev/null
    local f
    f=$(ls "$TEST_DIR/bk"/x-ui-*.db.gz | head -1)
    gzip -dc "$f" > "$TEST_DIR/restored.db"
    [ "$(sqlite3 "$TEST_DIR/restored.db" 'select count(*) from inbounds;')" = "1" ]
    [ "$(stat -c '%a' "$f")" = "600" ]
}

@test "backup: ротация оставляет ровно --keep копий" {
    for _ in 1 2 3; do
        bash "$REPO_ROOT/scripts/backup-db.sh" --db "$XUI_DB" --dir "$TEST_DIR/bk" --keep 2 >/dev/null
        sleep 1
    done
    [ "$(find "$TEST_DIR/bk" -name 'x-ui-*.db.gz' | wc -l)" -eq 2 ]
}

@test "backup: без БД — код 1 и внятная ошибка" {
    run bash "$REPO_ROOT/scripts/backup-db.sh" --db "$TEST_DIR/nope.db" --dir "$TEST_DIR/bk"
    [ "$status" -eq 1 ]
    [[ $output == *"нет БД"* ]]
}

@test "backup: --offsite без remote — ошибка, а не тихий локальный бэкап" {
    run bash "$REPO_ROOT/scripts/backup-db.sh" --db "$XUI_DB" --dir "$TEST_DIR/bk" \
        --offsite --rclone-remote "" --env-file /nonexistent
    [ "$status" -eq 1 ]
    [[ $output == *"RCLONE_REMOTE"* ]]
}

@test "check_no_secrets: чистый файл проходит, публичный IP — нет" {
    mkdir -p "$TEST_DIR/repo/scripts"
    cp "$REPO_ROOT/scripts/check_no_secrets.sh" "$TEST_DIR/repo/scripts/"
    echo "пример адреса 203.0.113.10 и <SERVER_IP>" > "$TEST_DIR/repo/clean.md"
    run bash "$TEST_DIR/repo/scripts/check_no_secrets.sh"
    [ "$status" -eq 0 ]

    echo "мой сервер 93.184.216.34" > "$TEST_DIR/repo/leak.md"  # secrets-ok: так проверяем детект
    run bash "$TEST_DIR/repo/scripts/check_no_secrets.sh"
    [ "$status" -eq 1 ]
    [[ $output == *"публичный IP"* ]]
}

@test "check_no_secrets: готовая ссылка и пароль тоже ловятся" {
    mkdir -p "$TEST_DIR/repo/scripts"
    cp "$REPO_ROOT/scripts/check_no_secrets.sh" "$TEST_DIR/repo/scripts/"
    printf 'vless://uuid@203.0.113.9:443?security=reality\n' > "$TEST_DIR/repo/link.md"  # secrets-ok
    printf 'password = hunter2hunter2\n' > "$TEST_DIR/repo/cred.md"  # secrets-ok
    run bash "$TEST_DIR/repo/scripts/check_no_secrets.sh"
    [ "$status" -eq 1 ]
    [[ $output == *"готовая ссылка"* ]]
    [[ $output == *"пароль/токен"* ]]
}

@test "все shell-скрипты репозитория синтаксически валидны" {
    while IFS= read -r f; do
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT" -maxdepth 1 -name '*.sh' -o -path '*/scripts/*.sh')
}

@test "watchdog: без env-файла не падает на разборе настроек" {
    run bash "$REPO_ROOT/scripts/watchdog.sh" --verbose
    [[ $output == *"ПРЕДУПРЕЖДЕНИЕ"* || $output == *"ОШИБКА"* ]]
}

@test "restore: .gz распаковывается, БД подменяется, панель «стартует»" {
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/x-ui"
    printf '#!/bin/sh\necho 200\n' > "$TEST_DIR/bin/curl"
    chmod +x "$TEST_DIR/bin/x-ui" "$TEST_DIR/bin/curl"

    gzip -c "$XUI_DB" > "$TEST_DIR/bk.db.gz"
    cp "$XUI_DB" "$TEST_DIR/target.db"
    : > "$TEST_DIR/target.db-wal"

    run env PATH="$TEST_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/restore-db.sh" \
        --yes --db "$TEST_DIR/target.db" "$TEST_DIR/bk.db.gz"
    [ "$status" -eq 0 ]
    [[ $output == *"PASS"* ]]
    [ "$(sqlite3 "$TEST_DIR/target.db" 'select count(*) from inbounds;')" = "1" ]
    [ ! -s "$TEST_DIR/target.db-wal" ]
    ls "$TEST_DIR"/target.db.before-restore.* >/dev/null
}

@test "restore: битый архив не трогает текущую БД" {
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/x-ui"
    printf '#!/bin/sh\necho 200\n' > "$TEST_DIR/bin/curl"
    chmod +x "$TEST_DIR/bin/x-ui" "$TEST_DIR/bin/curl"

    cp "$XUI_DB" "$TEST_DIR/target.db"
    echo "не sqlite" | gzip -c > "$TEST_DIR/junk.db.gz"
    run env PATH="$TEST_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/restore-db.sh" \
        --yes --db "$TEST_DIR/target.db" "$TEST_DIR/junk.db.gz"
    [ "$status" -ne 0 ]
    [[ $output == *"не прошёл integrity_check"* ]]
    [ "$(sqlite3 "$TEST_DIR/target.db" 'select count(*) from inbounds;')" = "1" ]
}
