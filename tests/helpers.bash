# Общие фикстуры для bats: временная БД 3x-ui и фальшивая панель в памяти.
# Подключается через `load helpers` из tests/*.bats.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export XUI="$REPO_ROOT/scripts/lib/xui.py"

setup_fixture() {
    TEST_DIR="$(mktemp -d)"
    export XUI_DB="$TEST_DIR/x-ui.db"
    export TEST_DIR
    python3 - "$XUI_DB" <<'PY'
import json, sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db)
c.executescript("""
create table settings (key text primary key, value text);
create table inbounds (id integer primary key, user_id int, up int, down int, total int,
  remark text, enable int, expiry_time int, listen text, port int, protocol text,
  settings text, stream_settings text, tag text, sniffing text);
""")
stream = {"network": "tcp", "security": "reality", "realitySettings": {
    "dest": "yahoo.com:443", "serverNames": ["yahoo.com"],
    "privateKey": "<PRIVATE_KEY>", "shortIds": ["ab12cd34"],
    "settings": {"publicKey": "<PUBLIC_KEY>", "fingerprint": "chrome",
                 "serverName": "yahoo.com", "spiderX": "/"}}}
clients = [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision",
            "email": "alice", "limitIp": 0, "totalGB": 0, "expiryTime": 0,
            "enable": True, "subId": "aaaa1111", "tgId": 0},
           {"id": "99999999-8888-7777-6666-555555555555", "flow": "xtls-rprx-vision",
            "email": "carol", "limitIp": 0, "totalGB": 0, "expiryTime": 0,
            "enable": True, "subId": "", "tgId": 0}]
c.execute("insert into inbounds values (1,1,0,0,0,'VLESS-443',1,0,'',8443,'vless',?,?,'in-8443','')",
          (json.dumps({"clients": clients, "decryption": "none"}), json.dumps(stream)))
for k, v in [("webPort", "2053"), ("webBasePath", ""), ("subEnable", "true"),
             ("subPort", "2096"), ("subPath", "/sub/"), ("subDomain", ""),
             ("subURI", ""), ("subCertFile", ""), ("subKeyFile", "")]:
    c.execute("insert into settings values (?,?)", (k, v))
c.commit()
PY
}

teardown_fixture() {
    [[ -n ${TEST_DIR:-} && -d $TEST_DIR ]] && rm -rf "$TEST_DIR"
}

start_panel() {
    local flavor=${1:-new}
    local portfile="$TEST_DIR/panel.port"
    rm -f "$portfile"
    python3 - "$XUI_DB" "$TEST_DIR/seed.json" <<'PYSEED'
import json, sqlite3, sys
db, out = sys.argv[1], sys.argv[2]
rows = sqlite3.connect(db).execute("select settings from inbounds").fetchall()
clients = []
for (raw,) in rows:
    clients += json.loads(raw or "{}").get("clients") or []
open(out, "w").write(json.dumps(clients))
PYSEED
    python3 "$BATS_TEST_DIRNAME/fake_panel.py" --flavor "$flavor" \
        --port-file "$portfile" --user admin --password secret \
        --seed-json "$TEST_DIR/seed.json" --db "$XUI_DB" \
        >"$TEST_DIR/panel.log" 2>&1 &
    PANEL_PID=$!
    local i=0
    while [[ ! -s $portfile ]] && (( i < 100 )); do
        sleep 0.05
        i=$((i + 1))
        kill -0 "$PANEL_PID" 2>/dev/null || break
    done
    [[ -s $portfile ]] || { echo "fake panel не поднялся" >&2; return 1; }
    PANEL_PORT="$(cat "$portfile")"
    export PANEL_PORT
}

stop_panel() {
    [[ -n ${PANEL_PID:-} ]] && kill "$PANEL_PID" 2>/dev/null || true
    wait "$PANEL_PID" 2>/dev/null || true
}
