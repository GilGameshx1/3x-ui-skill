#!/usr/bin/env bash
# Страж репозитория: падает, если в файлах навыка оказались реальные секреты —
# публичный IPv4, готовые vless:// / tg:// ссылки, приватные ключи, пароли.
#
#   bash scripts/check_no_secrets.sh          # проверить всё, что лежит в git
#   bash scripts/check_no_secrets.sh --all    # проверить и неотслеживаемые файлы
#
# Код возврата 1 = найдено, коммитить нельзя.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
MODE="${1:-tracked}"

exec python3 - "$MODE" <<'PY'
import ipaddress, os, re, subprocess, sys

mode = sys.argv[1]
SELF = "scripts/check_no_secrets.sh"
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2",
            ".ttf", ".zip", ".gz", ".db", ".so", ".bin"}

# Диапазоны, которые не считаем утечкой: приватные, служебные, документация.
def is_safe_ip(s):
    try:
        ip = ipaddress.IPv4Address(s)
    except ValueError:
        return True
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast \
       or ip.is_reserved or ip.is_unspecified:
        return True
    if str(ip) in {"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112"}:
        return True          # публичные DNS — это не секрет
    if ip in ipaddress.ip_network("203.0.113.0/24") or \
       ip in ipaddress.ip_network("198.51.100.0/24") or \
       ip in ipaddress.ip_network("192.0.2.0/24"):
        return True          # TEST-NET, годится для примеров
    return False

IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
LINK = re.compile(r"\b(?:vless|vmess|trojan|ss|hysteria2?)://(?!<|\{|\$)[^\s\"'`)]{8,}")
KEY  = re.compile(r"-----BEGIN (?:OPENSSH|RSA|EC|DSA|PRIVATE) PRIVATE KEY-----")
CRED = re.compile(r"(?i)\b(?:password|passwd|passphrase|secret|api[_-]?key|"
                  r"access[_-]?token|auth[_-]?token|token)\b\s*[=:]\s*"
                  r"[\"']?([^\s\"'`,;]{6,})")
PLACEHOLDER = re.compile(r"^[<$\{(\[]|[A-Z_]{3,}$|^(?:none|false|true|example|string|"
                         r"changeme|password|secret|token|xxx+|\*+)$")

def files():
    try:
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
        listed = [f for f in out.splitlines() if f]
        if mode == "--all":
            for root, dirs, names in os.walk("."):
                dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__"}]
                for n in names:
                    p = os.path.relpath(os.path.join(root, n), ".")
                    if p not in listed:
                        listed.append(p)
        return listed
    except Exception:
        listed = []
        for root, dirs, names in os.walk("."):
            dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__"}]
            listed += [os.path.relpath(os.path.join(root, n), ".") for n in names]
        return listed

findings = []
for path in files():
    if path == SELF or path.startswith(".github/"):
        continue
    if os.path.splitext(path)[1].lower() in SKIP_EXT or not os.path.isfile(path):
        continue
    try:
        text = open(path, encoding="utf-8", errors="strict").read()
    except (UnicodeDecodeError, OSError):
        continue
    for no, line in enumerate(text.splitlines(), 1):
        for m in IPV4.finditer(line):
            if not is_safe_ip(m.group()):
                findings.append((path, no, "публичный IP: " + m.group()))
        for m in LINK.finditer(line):
            findings.append((path, no, "готовая ссылка: " + m.group()[:40]))
        if KEY.search(line):
            findings.append((path, no, "приватный ключ в файле"))
        for m in CRED.finditer(line):
            val = m.group(1)
            if PLACEHOLDER.match(val) or val.startswith("<") or val.startswith("$"):
                continue
            if not re.search(r"[A-Za-z0-9]", val):
                continue   # кириллица / знаки — это текст, а не секрет
            findings.append((path, no, "похоже на пароль/токен: " + m.group()[:40]))

if findings:
    print("НАЙДЕНЫ СЕКРЕТЫ — коммитить нельзя:\n")
    for path, no, what in findings:
        print(f"  {path}:{no}  {what}")
    print(f"\nвсего: {len(findings)}")
    sys.exit(1)

print("OK: секретов не найдено")
PY
