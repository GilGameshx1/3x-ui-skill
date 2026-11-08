#!/usr/bin/env python3
"""Фальшивая панель 3x-ui для тестов: обе схемы API, без x-ui и без сети наружу.

  fake_panel.py --flavor new|old --port-file /tmp/port [--user admin --pass secret]

Порт выбирается свободный (bind 0), фактический пишется в --port-file, чтобы
bats-тест мог дождаться готовности. Клиенты живут в памяти процесса.
"""
import argparse
import json
import os
import secrets
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlparse

INBOUND = {
    "id": 1,
    "remark": "VLESS-443",
    "enable": True,
    "port": 8443,
    "protocol": "vless",
    "settings": json.dumps({"clients": [], "decryption": "none"}),
    "streamSettings": json.dumps({
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "yahoo.com:443",
            "serverNames": ["yahoo.com"],
            "privateKey": "<PRIVATE_KEY>",
            "shortIds": ["ab12cd34"],
            "settings": {"publicKey": "<PUBLIC_KEY>", "fingerprint": "chrome",
                         "serverName": "yahoo.com", "spiderX": "/"},
        },
    }),
}

STATE = {"clients": {}, "inbounds": {1: INBOUND}, "subs": {}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    flavor = "new"
    base_path = ""
    user = "admin"
    password = "secret"
    authed = set()
    db_path = None

    def log_message(self, *a):  # тишина в тестах
        pass

    # -- helpers -----------------------------------------------------
    def send_json(self, code, obj, cookie=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def cookie_ok(self):
        raw = self.headers.get("Cookie") or ""
        return any(p.strip() == "xui=ok" for p in raw.split(";"))

    def route(self):
        u = urlparse(self.path)
        path = u.path
        if self.base_path and path.startswith(self.base_path):
            path = path[len(self.base_path):]
        return path or "/", parse_qs(u.query)

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return {}

    def persist(self):
        """Как настоящая панель: изменения клиентов уходят в БД."""
        db = getattr(self, "db_path", None)
        if not db:
            return
        conn = sqlite3.connect(db)
        row = conn.execute("select settings from inbounds where id=1").fetchone()
        settings = json.loads((row or ["{}"])[0] or "{}")
        settings["clients"] = [r["client"] for r in STATE["clients"].values()]
        conn.execute("update inbounds set settings=? where id=1", (json.dumps(settings),))
        conn.commit()
        conn.close()

    # -- endpoints ---------------------------------------------------
    def do_POST(self):
        path, _ = self.route()
        if path == "/login":
            n = int(self.headers.get("Content-Length") or 0)
            form = {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode()).items()}
            if form.get("username") == self.user and form.get("password") == self.password:
                self.send_json(200, {"success": True, "msg": "ok"}, "xui=ok; Path=/")
            else:
                self.send_json(200, {"success": False, "msg": "denied"})
            return
        if not self.cookie_ok():
            self.send_json(401, {"success": False, "msg": "unauthorized"})
            return
        if path == "/panel/api/clients/add":
            payload = self.body_json()
            client = payload.get("client") or {}
            email = client.get("email")
            STATE["clients"][email] = {"client": client,
                                       "inboundIds": payload.get("inboundIds") or [1]}
            self.persist()
            self.send_json(200, {"success": True, "msg": "added"})
            return
        if path == "/panel/api/clients/update":
            payload = self.body_json()
            client = payload.get("client") or {}
            email = client.get("email")
            STATE["clients"][email] = {"client": client,
                                       "inboundIds": payload.get("inboundIds") or [1]}
            self.persist()
            self.send_json(200, {"success": True, "msg": "updated"})
            return
        if path == "/panel/api/inbounds/addClient":
            payload = self.body_json()
            inbound_id = int(payload.get("id") or 1)
            settings = json.loads(payload.get("settings") or "{}")
            for c in settings.get("clients") or []:
                STATE["clients"][c.get("email")] = {"client": c, "inboundIds": [inbound_id]}
            self.persist()
            self.send_json(200, {"success": True, "msg": "added"})
            return
        if path.startswith("/panel/api/inbounds/updateClient/"):
            payload = self.body_json()
            inbound_id = int(payload.get("id") or 1)
            settings = json.loads(payload.get("settings") or "{}")
            for c in settings.get("clients") or []:
                STATE["clients"][c.get("email")] = {"client": c, "inboundIds": [inbound_id]}
            self.persist()
            self.send_json(200, {"success": True, "msg": "updated"})
            return
        self.send_json(404, {"success": False, "msg": "no route " + path})

    def do_GET(self):
        path, _ = self.route()
        if path.startswith("/panel/api/") and not self.cookie_ok():
            self.send_json(401, {"success": False, "msg": "unauthorized"})
            return
        if path == "/panel/api/clients/list" and self.flavor == "new":
            self.send_json(200, {"success": True, "obj": list(STATE["clients"].values())})
            return
        if path.startswith("/panel/api/clients/get/") and self.flavor == "new":
            email = unquote(path.rsplit("/", 1)[-1])
            rec = STATE["clients"].get(email)
            if not rec:
                self.send_json(200, {"success": False, "obj": None})
            else:
                self.send_json(200, {"success": True, "obj": rec})
            return
        if path == "/panel/api/inbounds/list":
            self.send_json(200, {"success": True, "obj": list(STATE["inbounds"].values())})
            return
        if path.startswith("/panel/api/inbounds/get/"):
            try:
                ib = STATE["inbounds"][int(path.rsplit("/", 1)[-1])]
            except (ValueError, KeyError):
                self.send_json(404, {"success": False})
                return
            ib = dict(ib)
            clients = [r["client"] for r in STATE["clients"].values()]
            ib["settings"] = json.dumps({"clients": clients, "decryption": "none"})
            self.send_json(200, {"success": True, "obj": ib})
            return
        if path.startswith("/sub/"):
            sid = path[len("/sub/"):]
            links = [c["client"] for c in STATE["clients"].values() if c["client"].get("subId") == sid]
            body = "\n".join("vless://%s@127.0.0.1:8443?x=1" % c.get("id") for c in links).encode()
            self.send_response(200 if links else 404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_json(404, {"success": False, "msg": "no route " + path})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", choices=["new", "old"], default="new")
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--base-path", default="")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--db", default=None, help="БД, куда писать клиентов как панель")
    ap.add_argument("--seed-json", default=None,
                    help="файл со списком клиентов, уже существующих в панели")
    a = ap.parse_args()

    if a.seed_json:
        with open(a.seed_json) as f:
            for cl in json.load(f):
                STATE["clients"][cl.get("email")] = {"client": cl, "inboundIds": [1]}

    Handler.flavor = a.flavor
    Handler.base_path = a.base_path
    Handler.user = a.user
    Handler.password = a.password
    Handler.db_path = a.db

    srv = HTTPServer(("127.0.0.1", 0), Handler)
    with open(a.port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
