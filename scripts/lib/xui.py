#!/usr/bin/env python3
"""Клиенты и подписка 3x-ui без браузера: одна библиотека на все скрипты навыка.

Читает БД панели (sqlite3) и, когда нужно что-то создать, входит в её HTTP API
на 127.0.0.1. Работает и со старой схемой (клиенты в inbounds.settings), и с
новой (нормализованные таблицы clients/client_inbounds): наружу торчит API
панели, а не SQL.

Секреты: пароль панели читается из stdin или XUI_PASSWORD на один вызов и
никуда не пишется. Готовые vless:// и ссылки подписки печатаются в stdout —
это ответ пользователю, а не файл на диске.

Подкоманды:
  add            создать клиента (лимиты, срок, subId) и напечатать ссылки
  link           ссылка vless:// для существующего клиента
  sub-url        ссылка подписки для subId
  assign-subids  выдать subId клиентам, у которых его нет
  sub-setup      включить подписку в настройках панели и проверить её
  list           клиенты по входящим (JSON)
"""

import argparse
import ipaddress
import json
import os
import secrets
import shutil
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

DEFAULT_DB = "/etc/x-ui/x-ui.db"
XRAY_CANDIDATES = [
    "/usr/local/x-ui/bin/xray-linux-amd64",
    "/usr/local/x-ui/bin/xray-linux-arm64",
    "/usr/local/bin/xray",
    "/usr/local/x-ui/bin/xray",
]
FLOW_VISION = "xtls-rprx-vision"


class Fail(Exception):
    """Ошибка, которую надо показать человеку, а не трассировкой."""


# ---------------------------------------------------------------- утилиты

def die(msg, code=1):
    print("ОШИБКА: " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def new_uuid():
    return str(uuid4())


def uuid4():
    # uuid4 без импорта uuid ради совместимости со старыми 3.6-сборками python
    import uuid
    return uuid.uuid4()


def new_sub_id():
    return secrets.token_hex(8)


def utc_ms(days_from_now):
    return int((time.time() + days_from_now * 86400) * 1000)


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit in ("B", "KB") else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return "%d B" % n


# ---------------------------------------------------------------- БД

def connect(db, readonly=True):
    if not os.path.exists(db):
        raise Fail("БД панели не найдена: %s (панель установлена?)" % db)
    if readonly:
        uri = "file:%s?mode=ro" % urllib.parse.quote(os.path.abspath(db))
        conn = sqlite3.connect(uri, uri=True, timeout=5)
    else:
        conn = sqlite3.connect(db, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def read_settings(conn):
    try:
        return {r["key"]: r["value"] for r in conn.execute("SELECT key,value FROM settings")}
    except sqlite3.Error as e:
        raise Fail("не читается таблица settings: %s" % e)


def write_settings(conn, values):
    """Обновляет настройки панели. Значения — строки, как их хранит 3x-ui."""
    with conn:
        for key, val in values.items():
            cur = conn.execute("UPDATE settings SET value=? WHERE key=?", (str(val), key))
            if cur.rowcount == 0:
                conn.execute("INSERT INTO settings(key,value) VALUES(?,?)", (key, str(val)))


def get_inbound(conn, ident):
    if str(ident).isdigit():
        row = conn.execute("SELECT * FROM inbounds WHERE id=?", (int(ident),)).fetchone()
    else:
        row = conn.execute("SELECT * FROM inbounds WHERE remark=?", (str(ident),)).fetchone()
    if not row:
        raise Fail("входящее «%s» не найдено в БД" % ident)
    return dict(row)


def parse_json_field(row, field):
    raw = row.get(field) or "{}"
    try:
        return json.loads(raw)
    except ValueError:
        raise Fail("поле %s входящего id=%s — не JSON" % (field, row.get("id")))


def inbound_clients(conn, inbound):
    """Клиенты входящего: сначала settings JSON, затем нормализованные таблицы."""
    settings = parse_json_field(inbound, "settings")
    clients = settings.get("clients") or []
    if clients:
        return clients
    try:
        rows = conn.execute(
            "SELECT c.* FROM clients c JOIN client_inbounds ci ON ci.client_id=c.id "
            "WHERE ci.inbound_id=?", (inbound["id"],)).fetchall()
    except sqlite3.Error:
        return []
    out = []
    for r in rows:
        d = dict(r)
        client = {
            "email": d.get("email", ""),
            "id": d.get("uuid") or d.get("id_uuid") or d.get("client_id") or "",
            "flow": d.get("flow", ""),
            "subId": d.get("sub_id", ""),
            "limitIp": d.get("limit_ip", 0),
            "totalGB": d.get("total_gb", 0),
            "expiryTime": d.get("expiry_time", 0),
            "enable": bool(d.get("enable", 1)),
        }
        out.append(client)
    return out


# ---------------------------------------------------------------- Xray

def find_xray(explicit=None):
    env = os.environ.get("XRAY_BIN")
    for p in ([explicit] if explicit else []) + ([env] if env else []) + XRAY_CANDIDATES:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("xray")


def _key_bytes(value):
    """Декодирует base64/base64url-ключ в байты; None, если это не ключ."""
    import base64
    if not value:
        return None
    v = value.strip().replace("-", "+").replace("_", "/")
    v += "=" * ((4 - len(v) % 4) % 4)
    try:
        return base64.b64decode(v, validate=True)
    except Exception:  # noqa: BLE001 — любое несоответствие значит «не ключ»
        return None


def reality_public_key(stream):
    """Публичный ключ Reality: выводится из приватного, а не берётся из БД.

    Два отдельных вызова `xray x25519` дают две разные пары, поэтому сохранённый
    publicKey может не соответствовать приватному — тогда по такой ссылке никто
    не подключится. Истина только у `x25519 -i <privateKey>`.
    """
    rs = stream.get("realitySettings") or {}
    inner = rs.get("settings") or {}
    priv = rs.get("privateKey") or inner.get("privateKey")
    stored = rs.get("publicKey") or inner.get("publicKey")
    if priv:
        xray = find_xray()
        if xray:
            out = run([xray, "x25519", "-i", priv])
            derived = None
            for line in out.stdout.splitlines():
                low = line.strip().lower()
                if low.startswith(("password", "publickey", "public key")):
                    derived = line.split(":", 1)[1].strip()
            if derived:
                if stored and derived != stored:
                    # Та же пара в другой кодировке (base64 с паддингом вместо
                    # base64url) — это не расхождение ключей, но такая ссылка не
                    # подключается: молча отдаём канонический вариант.
                    same = _key_bytes(stored) == _key_bytes(derived)
                    if not same:
                        print("ВНИМАНИЕ: publicKey в панели из другой пары, чем "
                              "privateKey — в ссылку идёт выведенный ключ",
                              file=sys.stderr)
                return derived
    if stored:
        # Без xray (не 3x-ui-сервер) проверить нечем — берём как есть.
        return stored
    raise Fail("в streamSettings нет ни privateKey, ни publicKey — Reality не собрать")


# ---------------------------------------------------------------- ссылки

def q(**params):
    return urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")},
                                  quote_via=urllib.parse.quote, safe="")


def build_link(inbound, client, host, port=None, remark=None):
    stream = parse_json_field(inbound, "stream_settings")
    net = stream.get("network") or "tcp"
    sec = stream.get("security") or "none"
    port = port or inbound["port"]
    tag = remark or client.get("email") or inbound.get("remark") or "vpn"

    if sec == "reality":
        rs = stream.get("realitySettings") or {}
        inner = rs.get("settings") or {}
        params = dict(
            type=net, security="reality", pbk=reality_public_key(stream),
            fp=rs.get("fingerprint") or inner.get("fingerprint") or "chrome",
            sni=rs.get("serverName") or inner.get("serverName")
                or (rs.get("serverNames") or ["<SNI>"])[0],
            sid=(rs.get("shortId") or inner.get("shortId")
                 or ((rs.get("shortIds") or [""])[0])),
            spx=rs.get("spiderX") or inner.get("spiderX") or "/",
            flow=client.get("flow") or "",
        )
    elif sec in ("tls", "xtls"):
        params = dict(type=net, security="tls",
                      sni=stream.get("serverName") or (stream.get("tlsSettings") or {}).get("serverName"),
                      fp=(stream.get("tlsSettings") or {}).get("fingerprint") or "chrome",
                      flow=client.get("flow") or "")
    else:
        params = dict(type=net, security="none", flow=client.get("flow") or "")

    hostpart = host if ":" not in host else "[%s]" % host
    return "vless://%s@%s:%s?%s#%s" % (
        client.get("id") or "<UUID>", hostpart, port, q(**params),
        urllib.parse.quote(tag, safe=""))


def sub_base(settings, host, timeout_hint=True):
    """База подписки: схема, хост, порт, путь — как их собирает сама панель."""
    tls = bool(settings.get("subCertFile") and settings.get("subKeyFile"))
    scheme = "https" if tls else "http"
    port = int(settings.get("subPort") or 2096)
    path = settings.get("subPath") or "/sub/"
    if not path.startswith("/"):
        path = "/" + path
    if not path.endswith("/"):
        path += "/"
    dom = settings.get("subDomain") or ""
    uri = settings.get("subURI") or ""
    if uri:
        base = uri.rstrip("/") + "/"
    else:
        name = dom or host
        hostpart = name if ":" not in name else "[%s]" % name
        default_port = (port == 443 and tls) or (port == 80 and not tls)
        base = "%s://%s%s" % (scheme, hostpart, "" if default_port else ":" + str(port))
        base += path
    return base


def sub_url(settings, host, sub_id):
    return sub_base(settings, host) + sub_id


# ---------------------------------------------------------------- панель

class Panel(object):
    """Мини-клиент HTTP API панели. Сам определяет поколение API."""

    def __init__(self, port, base_path, host="127.0.0.1", username=None, password=None,
                 insecure=True, timeout=15):
        self.host = host
        self.port = int(port)
        self.base_path = "" if not base_path or base_path == "/" else "/" + base_path.strip("/")
        self.username = username
        self.password = password
        self.timeout = timeout
        ctx = ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        self.ctx = ctx
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(self.jar))
        self._scheme = None
        self._flavor = None

    # -- транспорт ---------------------------------------------------
    def _url(self, scheme, path):
        return "%s://%s:%d%s%s" % (scheme, self.host, self.port, self.base_path, path)

    def _raw(self, scheme, method, path, data=None, json_body=None, form=None):
        headers = {"Accept": "application/json"}
        body = None
        if json_body is not None:
            body = json.dumps(json_body).encode()
            headers["Content-Type"] = "application/json"
        elif form is not None:
            body = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(self._url(scheme, path), data=body, headers=headers,
                                     method=method)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                raw = r.read().decode("utf-8", "replace")
                code = r.status
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            code = e.code
        except (urllib.error.URLError, ssl.SSLError, OSError):
            raise
        try:
            obj = json.loads(raw) if raw.strip().startswith("{") else None
        except ValueError:
            obj = None
        return code, obj, raw

    def request(self, method, path, **kw):
        if self._scheme is None:
            last = None
            for scheme in ("https", "http"):
                try:
                    code, obj, raw = self._raw(scheme, method, path, **kw)
                    self._scheme = scheme
                    return code, obj, raw
                except (urllib.error.URLError, ssl.SSLError, OSError) as e:
                    last = e
            raise Fail("панель не отвечает на %s:%d (%s)" % (self.host, self.port, last))
        return self._raw(self._scheme, method, path, **kw)

    # -- сессия ------------------------------------------------------
    def login(self):
        if not self.username or self.password is None:
            raise Fail("нужны логин и пароль панели (--user/--password или XUI_USER/XUI_PASSWORD)")
        code, obj, raw = self.request(
            "POST", "/login", form={"username": self.username, "password": self.password})
        if not (obj and obj.get("success")):
            raise Fail("логин в панель не принят (HTTP %s): %s" % (code, (raw or "").strip()[:200]))
        return self

    def flavor(self):
        if self._flavor:
            return self._flavor
        code, obj, _ = self.request("GET", "/panel/api/clients/list")
        if code == 200 and obj is not None:
            self._flavor = "new"
            return self._flavor
        code, obj, _ = self.request("GET", "/panel/api/inbounds/list")
        if code == 200 and obj is not None:
            self._flavor = "old"
            return self._flavor
        raise Fail("не понял поколение API панели (ни /clients/list, ни /inbounds/list)")

    # -- операции ----------------------------------------------------
    def inbounds(self):
        code, obj, _ = self.request("GET", "/panel/api/inbounds/list")
        if code != 200 or not obj:
            raise Fail("GET /panel/api/inbounds/list → HTTP %s" % code)
        return obj.get("obj") or []

    def client_payload(self, email):
        code, obj, _ = self.request("GET", "/panel/api/clients/get/" + urllib.parse.quote(email))
        if code != 200 or not obj or not obj.get("obj"):
            return None
        return obj["obj"]

    def add_client(self, inbound_id, client):
        if self.flavor() == "new":
            body = {"client": client, "inboundIds": [int(inbound_id)]}
            code, obj, raw = self.request("POST", "/panel/api/clients/add", json_body=body)
        else:
            body = {"id": int(inbound_id),
                    "settings": json.dumps({"clients": [client]})}
            code, obj, raw = self.request("POST", "/panel/api/inbounds/addClient",
                                          json_body=body)
        if code != 200 or not (obj and obj.get("success")):
            raise Fail("панель отказала в создании клиента (HTTP %s): %s"
                       % (code, (raw or "").strip()[:300]))
        return obj

    def update_client(self, email, client):
        if self.flavor() == "new":
            inbound_ids = (self.client_payload(email) or {}).get("inboundIds") or []
            body = {"client": client, "inboundIds": inbound_ids}
            code, obj, raw = self.request("POST", "/panel/api/clients/update",
                                          json_body=body)
        else:
            body = {"id": int(client["_inbound_id"]),
                    "settings": json.dumps({"clients": [{k: v for k, v in client.items()
                                                         if k != "_inbound_id"}]})}
            code, obj, raw = self.request(
                "POST", "/panel/api/inbounds/updateClient/" + urllib.parse.quote(
                    client.get("id") or email), json_body=body)
        if code != 200 or not (obj and obj.get("success")):
            raise Fail("панель отказала в обновлении клиента %s (HTTP %s): %s"
                       % (email, code, (raw or "").strip()[:300]))
        return obj

    def get_client(self, inbound_id, email):
        """Карточка клиента из панели (источник истины, в отличие от БД)."""
        if self.flavor() == "new":
            payload = self.client_payload(email) or {}
            cl = payload.get("client") or {}
            return cl if cl.get("email") == email else None
        code, obj, _ = self.request("GET", "/panel/api/inbounds/get/%d" % int(inbound_id))
        if code != 200 or not obj:
            return None
        settings = ((obj.get("obj") or {}).get("settings")) or "{}"
        try:
            clients = (json.loads(settings).get("clients") or [])
        except ValueError:
            return None
        for c in clients:
            if c.get("email") == email:
                return c
        return None

    def has_client(self, inbound_id, email, uuid=None):
        """Проверка по факту: клиент реально виден панели после создания."""
        cl = self.get_client(inbound_id, email)
        return bool(cl and (not uuid or cl.get("id") == uuid))


# ---------------------------------------------------------------- команды

def panel_from_db(conn, args):
    settings = read_settings(conn)
    port = args.panel_port or settings.get("webPort") or 2053
    base = args.base_path if args.base_path is not None else settings.get("webBasePath") or ""
    user = args.user or os.environ.get("XUI_USER") or "admin"
    return Panel(port, base, username=user, password=args.password)


def load_password(args):
    if args.password is not None:
        return args.password
    env = os.environ.get("XUI_PASSWORD")
    if env is not None:
        return env
    if sys.stdin.isatty():
        import getpass
        return getpass.getpass("пароль панели (не эхоится): ")
    raise Fail("пароль панели не задан: используйте --password, XUI_PASSWORD или stdin")


def client_object(args, uuid, sub_id):
    return {
        "id": uuid,
        "email": args.email,
        "flow": args.flow or "",
        "limitIp": int(args.limit_ip or 0),
        "totalGB": int(float(args.quota_gb) * 1024 ** 3) if args.quota_gb else 0,
        "expiryTime": utc_ms(float(args.expiry_days)) if args.expiry_days else 0,
        "enable": True,
        "subId": sub_id or "",
        "tgId": int(args.tg_id or 0),
        "comment": args.comment or "",
        "reset": 0,
    }


def cmd_add(args):
    conn = connect(args.db)
    inbound = get_inbound(conn, args.inbound)
    settings = read_settings(conn)

    uuid = args.uuid or new_uuid()
    sub_id = args.sub_id if args.sub_id is not None else (
        new_sub_id() if str(settings.get("subEnable", "")).lower() in ("true", "1") else "")
    client = client_object(args, uuid, sub_id)

    if args.dry_run:
        print(json.dumps({"dry_run": True, "inbound": inbound["id"], "client": client},
                         ensure_ascii=False, indent=2))
        return 0

    if args.db_only:
        raise Fail("--db-only не поддерживается: клиента создаёт панель через API, "
                   "иначе расходятся нормализованные таблицы и статистика")

    panel = panel_from_db(conn, args)
    if args.password is None:
        args.password = load_password(args)
        panel.password = args.password
    panel.login()

    # Источник истины — панель: БД может отставать на несколько секунд.
    current = panel.get_client(inbound["id"], args.email)
    if current and not args.update:
        raise Fail("клиент %s уже есть во входящем %s (--update — обновить)"
                   % (args.email, inbound["id"]))

    if current:
        merged = dict(current)
        merged.update({k: v for k, v in client.items()
                       if k in ("flow", "limitIp", "totalGB", "expiryTime",
                                "tgId", "comment") and v not in (0, "", None)})
        merged["id"] = args.uuid or current.get("id") or uuid
        merged["subId"] = args.sub_id if args.sub_id is not None else (
            current.get("subId") or client["subId"])
        merged["email"] = args.email
        merged["enable"] = True
        merged["_inbound_id"] = inbound["id"]
        panel.update_client(args.email, merged)
        client, action = merged, "обновлён"
    else:
        panel.add_client(inbound["id"], client)
        action = "создан"

    if not panel.has_client(inbound["id"], args.email, client["id"]):
        raise Fail("клиент %s не найден в панели после создания — проверьте логи x-ui"
                   % args.email)

    host = args.host or public_ip()
    link = build_link(inbound, client, host)
    out = {
        "action": action,
        "inbound": inbound["id"],
        "inbound_remark": inbound.get("remark"),
        "email": args.email,
        "uuid": client["id"],
        "sub_id": client.get("subId") or "",
        "link": link,
        "sub_url": sub_url(settings, host, client["subId"]) if client.get("subId") else None,
    }
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print("Клиент %s %s (входящее %s, %s)" % (args.email, action, inbound["id"],
                                                  inbound.get("remark") or "-"))
        print("  UUID:  %s" % client["id"])
        if client.get("subId"):
            print("  subId: %s" % client["subId"])
        print("  Ссылка (показать и не сохранять в файлы):")
        print("    " + link)
        if out["sub_url"]:
            print("  Подписка: %s" % out["sub_url"])
        if client.get("expiryTime"):
            print("  Срок: до %s" % time.strftime("%Y-%m-%d %H:%M UTC",
                                                  time.gmtime(client["expiryTime"] / 1000)))
        if client.get("totalGB"):
            print("  Лимит: %s" % human_bytes(client["totalGB"]))
    return 0


def cmd_link(args):
    conn = connect(args.db)
    inbound = get_inbound(conn, args.inbound)
    client = next((c for c in inbound_clients(conn, inbound) if c.get("email") == args.email), None)
    if not client:
        raise Fail("клиент %s не найден во входящем %s" % (args.email, inbound["id"]))
    print(build_link(inbound, client, args.host or public_ip()))
    return 0


def cmd_sub_url(args):
    conn = connect(args.db)
    settings = read_settings(conn)
    if str(settings.get("subEnable", "")).lower() not in ("true", "1"):
        raise Fail("подписка выключена: сначала scripts/sub_setup.sh")
    print(sub_url(settings, args.host or public_ip(), args.sub_id))
    return 0


def cmd_assign_subids(args):
    conn = connect(args.db)
    settings = read_settings(conn)
    if str(settings.get("subEnable", "")).lower() not in ("true", "1"):
        raise Fail("подписка выключена: сначала scripts/sub_setup.sh")
    inbounds = ([get_inbound(conn, args.inbound)] if args.inbound
                else [dict(r) for r in conn.execute("SELECT * FROM inbounds")])
    todo = [(ib, c) for ib in inbounds for c in inbound_clients(conn, ib) if not c.get("subId")]
    if not todo:
        print("Все клиенты уже имеют subId.")
        return 0

    panel = panel_from_db(conn, args)
    if args.password is None:
        args.password = load_password(args)
        panel.password = args.password
    panel.login()

    done = 0
    for ib, cl in todo:
        sid = new_sub_id()
        if panel.flavor() == "new":
            payload = panel.client_payload(cl["email"]) or {}
            rec = payload.get("client") or {}
            if not rec:
                print("  ! %s: панель не отдала карточку клиента" % cl["email"])
                continue
            rec["subId"] = sid
            panel.update_client(cl["email"], rec)
        else:
            client = dict(cl, subId=sid, _inbound_id=ib["id"])
            panel.update_client(cl["email"], client)
        done += 1
        print("  + %s → subId %s" % (cl["email"], sid))
    print("Выдано subId: %d из %d" % (done, len(todo)))
    return 0 if done == len(todo) else 1


def cmd_sub_setup(args):
    conn = connect(args.db)
    settings = read_settings(conn)
    port = int(args.sub_port or settings.get("subPort") or 2096)
    path = args.sub_path or settings.get("subPath") or "/sub/"
    values = {
        "subEnable": "true",
        "subPort": str(port),
        "subPath": path,
    }
    if args.sub_domain:
        values["subDomain"] = args.sub_domain
    if args.sub_uri:
        values["subURI"] = args.sub_uri
    if args.dry_run:
        print(json.dumps({"dry_run": True, "settings": values}, ensure_ascii=False, indent=2))
        return 0

    changed = {k: v for k, v in values.items() if str(settings.get(k, "")) != str(v)}
    if changed:
        write_settings(conn, changed)
        print("Настройки подписки обновлены: " + ", ".join(sorted(changed)))
        if not args.no_restart:
            print("Перезапускаю панель, чтобы она подхватила новые настройки…")
            subprocess.run(["x-ui", "restart"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(3)
    else:
        print("Настройки подписки уже верные — ничего не меняю.")

    settings = read_settings(connect(args.db))
    host = args.host or public_ip()
    print("Подписка: %s" % sub_base(settings, host) + "<subId>")

    # Проверка по факту: панель должна отдать файл подписки по этому пути.
    probe_id = args.probe_sub_id or first_sub_id(conn)
    if probe_id:
        url = sub_url(settings, host, probe_id).replace(host, "127.0.0.1", 1)
        ok, detail = probe_subscription(url)
        print(("PASS: подписка отдаёт ссылки (%s)" if ok else "FAIL: подписка не отвечает (%s)")
              % detail)
        if not ok:
            return 2
    else:
        print("WARN: ни у одного клиента нет subId — проверка подписки пропущена "
              "(scripts/sub_setup.sh --assign-subids)")
    return 0


def first_sub_id(conn):
    for row in conn.execute("SELECT settings FROM inbounds"):
        try:
            for c in (json.loads(row["settings"] or "{}").get("clients") or []):
                if c.get("subId"):
                    return c["subId"]
        except ValueError:
            continue
    try:
        row = conn.execute("SELECT sub_id FROM clients WHERE sub_id != '' LIMIT 1").fetchone()
        return row["sub_id"] if row else None
    except sqlite3.Error:
        return None


def probe_subscription(url):
    """GET по ссылке подписки: ждём vless:// или base64 с ним внутри."""
    import base64
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(url, timeout=10, context=ctx) as r:
            body = r.read().decode("utf-8", "replace")
            code = r.status
    except urllib.error.HTTPError as e:
        return False, "HTTP %s" % e.code
    except Exception as e:  # noqa: BLE001 — нужен любой сбой сети/TLS
        return False, str(e)[:120]
    text = body
    if "vless://" not in text:
        try:
            decoded = base64.b64decode(body + "=" * (-len(body) % 4)).decode("utf-8", "replace")
            if "vless://" in decoded:
                text = decoded
        except Exception:  # noqa: BLE001
            pass
    if "vless://" not in text:
        return False, "HTTP %s, но в ответе нет vless://" % code
    return True, "HTTP %s, ссылки на месте" % code


def cmd_list(args):
    conn = connect(args.db)
    rows = [dict(r) for r in conn.execute("SELECT * FROM inbounds ORDER BY id")]
    out = []
    now = int(time.time() * 1000)
    for ib in rows:
        clients = inbound_clients(conn, ib)
        out.append({
            "id": ib["id"], "remark": ib.get("remark"), "port": ib.get("port"),
            "protocol": ib.get("protocol"), "enable": bool(ib.get("enable")),
            "clients": [{
                "email": c.get("email"), "uuid": c.get("id"),
                "flow": c.get("flow") or "", "subId": c.get("subId") or "",
                "enable": bool(c.get("enable", True)),
                "expired": bool(c.get("expiryTime") and c["expiryTime"] < now),
                "expiryTime": c.get("expiryTime") or 0,
                "quota": c.get("totalGB") or 0,
                "limitIp": c.get("limitIp") or 0,
            } for c in clients],
        })
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def public_ip():
    """Публичный IPv4 хоста. Нужен только для сборки ссылки, не для проверки."""
    for url in ("https://ipv4.icanhazip.com", "https://api.ipify.org"):
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                ip = r.read().decode().strip()
            ipaddress.ip_address(ip)
            return ip
        except Exception:  # noqa: BLE001
            continue
    return "<SERVER_IP>"


def add_common(p):
    p.add_argument("--db", default=os.environ.get("XUI_DB", DEFAULT_DB))
    p.add_argument("--user", default=None, help="логин панели (или XUI_USER)")
    p.add_argument("--password", default=None, help="пароль панели (или XUI_PASSWORD)")
    p.add_argument("--panel-port", default=None, help="порт панели (по умолчанию из БД)")
    p.add_argument("--base-path", default=None, help="webBasePath (по умолчанию из БД)")
    p.add_argument("--json", action="store_true", help="машинный вывод")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Клиенты и подписка 3x-ui")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("add", help="создать клиента")
    add_common(p)
    p.add_argument("--inbound", required=True, help="id или remark входящего")
    p.add_argument("--email", required=True, help="имя клиента в панели")
    p.add_argument("--uuid", default=None)
    p.add_argument("--flow", default=FLOW_VISION)
    p.add_argument("--expiry-days", default=None, help="срок в днях (дробный можно)")
    p.add_argument("--quota-gb", default=None)
    p.add_argument("--limit-ip", default=None)
    p.add_argument("--tg-id", default=None)
    p.add_argument("--comment", default=None)
    p.add_argument("--sub-id", default=None)
    p.add_argument("--host", default=None, help="адрес для ссылок (по умолчанию публичный IP)")
    p.add_argument("--update", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--db-only", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("link", help="ссылка для клиента")
    add_common(p)
    p.add_argument("--inbound", required=True)
    p.add_argument("--email", required=True)
    p.add_argument("--host", default=None)
    p.set_defaults(func=cmd_link)

    p = sub.add_parser("sub-url", help="ссылка подписки")
    add_common(p)
    p.add_argument("--sub-id", required=True)
    p.add_argument("--host", default=None)
    p.set_defaults(func=cmd_sub_url)

    p = sub.add_parser("assign-subids", help="выдать subId старым клиентам")
    add_common(p)
    p.add_argument("--inbound", default=None)
    p.set_defaults(func=cmd_assign_subids)

    p = sub.add_parser("sub-setup", help="включить подписку")
    add_common(p)
    p.add_argument("--sub-port", default=None)
    p.add_argument("--sub-path", default=None)
    p.add_argument("--sub-domain", default=None)
    p.add_argument("--sub-uri", default=None)
    p.add_argument("--host", default=None)
    p.add_argument("--probe-sub-id", default=None)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-restart", action="store_true")
    p.set_defaults(func=cmd_sub_setup)

    p = sub.add_parser("list", help="клиенты по входящим (JSON)")
    add_common(p)
    p.set_defaults(func=cmd_list)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except Fail as e:
        die(str(e))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
