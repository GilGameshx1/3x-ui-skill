#!/usr/bin/env bats
# Клиенты и подписка: создание через API обеих схем, ссылки, subId.

load helpers

setup() {
    setup_fixture
    start_panel new
}

teardown() {
    stop_panel
    teardown_fixture
}

add_json() {
    python3 "$XUI" add --db "$XUI_DB" --inbound 1 --email "$1" \
        --panel-port "$PANEL_PORT" --user admin --password secret \
        --host 203.0.113.10 --json "${@:2}"
}

@test "link: строит vless reality со SNI и shortId" {
    run python3 "$XUI" link --db "$XUI_DB" --inbound 1 --email alice --host 203.0.113.10
    [ "$status" -eq 0 ]
    [[ $output == vless://11111111-2222-3333-4444-555555555555@203.0.113.10:8443* ]]  # secrets-ok: фикстура
    [[ $output == *"security=reality"* ]]
    [[ $output == *"sni=yahoo.com"* ]]
    [[ $output == *"sid=ab12cd34"* ]]
    [[ $output == *"flow=xtls-rprx-vision"* ]]
}

@test "sub-url: собирается из settings и subId" {
    run python3 "$XUI" sub-url --db "$XUI_DB" --sub-id aaaa1111 --host 203.0.113.10
    [ "$status" -eq 0 ]
    [ "$output" = "http://203.0.113.10:2096/sub/aaaa1111" ]
}

@test "add: создаёт клиента через API и печатает ссылку с subId" {
    run add_json bob --expiry-days 30 --quota-gb 5 --limit-ip 2
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["action"]=="создан", d
assert len(d["uuid"])==36
assert len(d["sub_id"])==16
assert d["link"].startswith("vless://")
assert d["sub_url"].endswith(d["sub_id"])
assert d["link"].count("pbk=")==1
'
}

@test "add: второй раз то же имя — ошибка без --update" {
    add_json bob >/dev/null
    run add_json bob
    [ "$status" -ne 0 ]
    [[ $output == *"уже есть"* ]]
}

@test "add: --update меняет лимиты, не плодит клиента" {
    add_json bob --quota-gb 5 >/dev/null
    run add_json bob --update --quota-gb 50
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["action"]=="обновлён", d
'
}

@test "add: работает со старой схемой API" {
    stop_panel
    start_panel old
    run add_json dave
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["action"]=="создан"'
}

@test "add: неверный пароль панели — внятная ошибка, без утечки пароля" {
    run python3 "$XUI" add --db "$XUI_DB" --inbound 1 --email eve \
        --panel-port "$PANEL_PORT" --user admin --password wrong --host 203.0.113.10
    [ "$status" -ne 0 ]
    [[ $output == *"логин в панель не принят"* ]]
    [[ $output != *"wrong"* ]]
}

@test "assign-subids: выдаёт subId клиенту без него" {
    run python3 "$XUI" assign-subids --db "$XUI_DB" --panel-port "$PANEL_PORT" \
        --user admin --password secret
    [ "$status" -eq 0 ]
    [[ $output == *"carol"* ]]
    run python3 "$XUI" list --db "$XUI_DB"
    echo "$output" | python3 -c '
import json,sys
data=json.load(sys.stdin)
subs={c["email"]:c["subId"] for c in data[0]["clients"]}
assert subs["alice"]=="aaaa1111", subs
assert len(subs["carol"])==16, subs
'
}

@test "sub-setup: --dry-run не трогает БД" {
    local before
    before=$(python3 -c "import sqlite3;print(sqlite3.connect('$XUI_DB').execute('select value from settings where key=\"subPort\"').fetchone()[0])")
    run python3 "$XUI" sub-setup --db "$XUI_DB" --sub-port 2087 --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"2087"* ]]
    [ "$before" = "2096" ]
}

@test "sub-setup: выключает понятную ошибку, когда подписка off" {
    python3 - "$XUI_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("update settings set value='false' where key='subEnable'"); c.commit()
PY
    run python3 "$XUI" sub-url --db "$XUI_DB" --sub-id aaaa1111 --host 203.0.113.10
    [ "$status" -ne 0 ]
    [[ $output == *"подписка выключена"* ]]
}
