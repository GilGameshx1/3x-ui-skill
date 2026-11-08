#!/usr/bin/env bash
# Второй транспорт: Hysteria2 на sing-box рядом с 3x-ui / VLESS Reality.
#
# Что делает:
#   1) ставит sing-box официальным установщиком (если бинаря нет);
#   2) собирает inbound hysteria2 в /etc/sing-box/config.json, сохраняя чужие inbound'ы;
#   3) готовит TLS: acme.sh (домен или IP-сертификат shortlived) | self-signed | внешний;
#   4) проверяет конфиг через `sing-box check`, ставит systemd unit (если его нет),
#      открывает UDP-порт в ufw;
#   5) печатает hysteria2:// ссылку ОДИН раз в stdout. В файлы и journal пароль не попадает.
#
# Идемпотентность: при повторном запуске пароль, obfs-пароль, masquerade и TLS-пути
# переиспользуются из существующего конфига; self-signed сертификат не перевыпускается,
# пока не истекает; сервис перезапускается только если конфиг реально изменился.
#
# Примеры:
#   sudo ./install_singbox_hysteria2.sh --domain vpn.example.com --cert-mode acme --acme-email you@example.com
#   sudo ./install_singbox_hysteria2.sh --ip 203.0.113.10 --port 8443 --obfs salamander
#   sudo ./install_singbox_hysteria2.sh --cert-mode none --cert /root/cert/fullchain.pem --key /root/cert/privkey.pem
#   ./install_singbox_hysteria2.sh --dry-run --domain vpn.example.com --cert-mode selfsigned
#
# Код возврата: 0 — успех (ссылка напечатана), 1 — ошибка (текст в stderr).
set -euo pipefail

PORT_ARG=""
LISTEN="::"
CONFIG="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box/certs"
CERT_MODE_ARG=""
DOMAIN=""
IP_ARG=""
PASSWORD_ARG=""
OBFS_ARG=""
OBFS_PASSWORD_ARG=""
MASQ_ARG=""
MASQ_SET=0
CERT_ARG=""
KEY_ARG=""
CHECK_CERT=""
CHECK_KEY=""
CERT_ROTATED=0
ACME_EMAIL_ARG=""
ACME_WEBROOT_ARG=""
TAG="hy2-in"
DRY_RUN=0
FORCE=0
NO_UFW=0
NO_SERVICE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Всё, кроме ссылки, идёт в stderr: stdout остаётся машинно-читаемым.
say()  { printf '%b\n' "$*" >&2; }
info() { say "${CYAN}==>${NC} $*"; }
ok()   { say "${GREEN}ok${NC}  $*"; }
warn() { say "${YELLOW}!${NC}   $*"; }
die()  { say "${RED}ошибка:${NC} $*"; exit 1; }

usage() {
    # печатаем только шапку-комментарий, без кода ниже
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
    cat >&2 <<'TXT'

Опции:
  --domain <fqdn>        TLS server_name (SNI) и имя для acme.sh
  --ip <addr>            публичный IPv4/IPv6 (по умолчанию определяется через ifconfig.me)
  --port <n>             UDP-порт inbound'а (по умолчанию 443)
  --password <pass>      пароль клиента (по умолчанию: из существующего конфига либо случайный)
  --obfs [salamander|off]  обфускация QUIC (по умолчанию off)
  --obfs-password <pass> пароль salamander (по умолчанию случайный)
  --masquerade <url>     https://... (reverse proxy), file:///path (статика) или none (404)
  --cert-mode <mode>     acme | selfsigned | none (по умолчанию: авто — см. ниже)
  --cert <path>          готовый fullchain (для --cert-mode none)
  --key <path>           готовый приватный ключ (для --cert-mode none)
  --acme-email <mail>    e-mail для аккаунта Let's Encrypt
  --acme-webroot <dir>   выпуск через webroot вместо --standalone (порт 80 занят nginx)
  --tag <name>           тег inbound'а (по умолчанию hy2-in)
  --config <path>        путь к config.json (по умолчанию /etc/sing-box/config.json)
  --cert-dir <path>      каталог сертификатов (по умолчанию /etc/sing-box/certs)
  --no-ufw               не трогать ufw
  --no-service           не ставить/не перезапускать systemd unit
  --force                перевыпустить self-signed серт, занять порт, заменить битый конфиг
  --dry-run              ничего не менять: собрать конфиг во временном каталоге и проверить
  -h, --help             эта справка

Режим TLS по умолчанию (auto): если в существующем конфиге уже есть рабочие пути
к сертификату — они переиспользуются; иначе выпускается self-signed (EC P-256, SAN IP/DNS).
TXT
}

need_value() { [[ $# -ge 2 && -n ${2:-} ]] || die "опция $1 требует значения"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)          need_value "$@"; DOMAIN="$2"; shift 2 ;;
        --domain=*)        DOMAIN="${1#*=}"; shift ;;
        --ip)              need_value "$@"; IP_ARG="$2"; shift 2 ;;
        --ip=*)            IP_ARG="${1#*=}"; shift ;;
        --port)            need_value "$@"; PORT_ARG="$2"; shift 2 ;;
        --port=*)          PORT_ARG="${1#*=}"; shift ;;
        --password)        need_value "$@"; PASSWORD_ARG="$2"; shift 2 ;;
        --password=*)      PASSWORD_ARG="${1#*=}"; shift ;;
        --obfs)            OBFS_ARG="salamander"
                           if [[ ${2:-} == salamander || ${2:-} == off ]]; then OBFS_ARG="$2"; shift; fi
                           shift ;;
        --obfs=*)          OBFS_ARG="${1#*=}"; shift ;;
        --obfs-password)   need_value "$@"; OBFS_PASSWORD_ARG="$2"; shift 2 ;;
        --obfs-password=*) OBFS_PASSWORD_ARG="${1#*=}"; shift ;;
        --masquerade)      need_value "$@"; MASQ_ARG="$2"; MASQ_SET=1; shift 2 ;;
        --masquerade=*)    MASQ_ARG="${1#*=}"; MASQ_SET=1; shift ;;
        --cert-mode)       need_value "$@"; CERT_MODE_ARG="$2"; shift 2 ;;
        --cert-mode=*)     CERT_MODE_ARG="${1#*=}"; shift ;;
        --cert)            need_value "$@"; CERT_ARG="$2"; shift 2 ;;
        --cert=*)          CERT_ARG="${1#*=}"; shift ;;
        --key)             need_value "$@"; KEY_ARG="$2"; shift 2 ;;
        --key=*)           KEY_ARG="${1#*=}"; shift ;;
        --acme-email)      need_value "$@"; ACME_EMAIL_ARG="$2"; shift 2 ;;
        --acme-email=*)    ACME_EMAIL_ARG="${1#*=}"; shift ;;
        --acme-webroot)    need_value "$@"; ACME_WEBROOT_ARG="$2"; shift 2 ;;
        --acme-webroot=*)  ACME_WEBROOT_ARG="${1#*=}"; shift ;;
        --tag)             need_value "$@"; TAG="$2"; shift 2 ;;
        --tag=*)           TAG="${1#*=}"; shift ;;
        --config)          need_value "$@"; CONFIG="$2"; shift 2 ;;
        --config=*)        CONFIG="${1#*=}"; shift ;;
        --cert-dir)        need_value "$@"; CERT_DIR="$2"; shift 2 ;;
        --cert-dir=*)      CERT_DIR="${1#*=}"; shift ;;
        --no-ufw)          NO_UFW=1; shift ;;
        --no-service)      NO_SERVICE=1; shift ;;
        --force)           FORCE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "неизвестная опция: $1 (--help)" ;;
    esac
done

[[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] || die "нужен root: sudo $0 ..."
command -v python3 >/dev/null || die "нужен python3 (apt install -y python3)"
command -v openssl >/dev/null || die "нужен openssl (apt install -y openssl)"

if [[ -n $CERT_MODE_ARG ]]; then
    case "$CERT_MODE_ARG" in
        acme|selfsigned|none) CERT_MODE="$CERT_MODE_ARG" ;;
        auto) CERT_MODE="auto" ;;
        *) die "--cert-mode: ожидается acme|selfsigned|none, получено '$CERT_MODE_ARG'" ;;
    esac
else
    CERT_MODE="auto"
fi

case "${OBFS_ARG:-off}" in
    off|"") OBFS_ARG="" ;;
    salamander) ;;
    *) die "--obfs: поддерживается только salamander (или off)" ;;
esac

if [[ -n $DOMAIN && ! $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    die "--domain: '$DOMAIN' не похоже на DNS-имя"
fi

# --- IP: аргумент, иначе определение снаружи ---------------------------------
detect_ip() {
    local ip=""
    if command -v curl >/dev/null; then
        ip=$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
        [[ -n $ip ]] || ip=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z $ip ]]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
    fi
    printf '%s' "$ip"
}

if [[ -n $IP_ARG ]]; then
    PUBLIC_IP="$IP_ARG"
elif [[ -n $DOMAIN && $CERT_MODE == acme ]]; then
    PUBLIC_IP=$(detect_ip)
else
    PUBLIC_IP=$(detect_ip)
fi

if [[ -n $PUBLIC_IP ]]; then
    python3 - "$PUBLIC_IP" <<'PY' >/dev/null 2>&1 || die "некорректный IP: $PUBLIC_IP"
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
elif [[ $DRY_RUN -eq 1 ]]; then
    PUBLIC_IP="203.0.113.10"
    warn "IP не определён — для dry-run подставлен TEST-NET 203.0.113.10"
else
    die "не удалось определить публичный IP; укажите --ip или --domain"
fi

[[ -n $DOMAIN || -n $PUBLIC_IP ]] || die "нужен --domain или --ip"
if [[ $CERT_MODE == acme && -z $DOMAIN && -z $IP_ARG ]]; then
    die "--cert-mode acme для IP требует явного --ip (сертификат Let's Encrypt на конкретный адрес)"
fi

HOST_FOR_LINK="${DOMAIN:-$PUBLIC_IP}"
HOST_IN_LINK="$HOST_FOR_LINK"
[[ $HOST_FOR_LINK == *:* ]] && HOST_IN_LINK="[$HOST_FOR_LINK]"

TMP=""
cleanup() { if [[ -n $TMP && $DRY_RUN -eq 0 ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hy2.XXXXXX")

# --- читаем, что уже настроено ----------------------------------------------
EX_PORT=""; EX_PASSWORD=""; EX_OBFS_TYPE=""; EX_OBFS_PASSWORD=""
EX_MASQ=""; EX_SNI=""; EX_CERT=""; EX_KEY=""; EX_JSON_OK=0

read_existing() {
    python3 - "$CONFIG" <<'PY'
import json, sys

path = sys.argv[1]


def emit(key, value):
    if value is None:
        return
    text = str(value).replace("\t", " ").replace("\n", " ")
    if text:
        print(f"{key}\t{text}")


try:
    with open(path, encoding="utf-8") as handle:
        cfg = json.load(handle)
except (OSError, ValueError):
    emit("json_ok", "0")
    raise SystemExit(0)

if not isinstance(cfg, dict):
    emit("json_ok", "0")
    raise SystemExit(0)

emit("json_ok", "1")
for inbound in cfg.get("inbounds") or []:
    if not isinstance(inbound, dict) or inbound.get("type") != "hysteria2":
        continue
    emit("port", inbound.get("listen_port"))
    users = inbound.get("users") or []
    if users and isinstance(users[0], dict):
        emit("password", users[0].get("password"))
    obfs = inbound.get("obfs")
    if isinstance(obfs, dict):
        emit("obfs_type", obfs.get("type"))
        emit("obfs_password", obfs.get("password"))
    masq = inbound.get("masquerade")
    if isinstance(masq, dict):
        if masq.get("type") == "proxy":
            emit("masquerade", masq.get("url"))
        elif masq.get("type") == "file":
            emit("masquerade", "file://" + str(masq.get("directory") or ""))
    elif isinstance(masq, str):
        emit("masquerade", masq)
    tls = inbound.get("tls")
    if isinstance(tls, dict):
        emit("sni", tls.get("server_name"))
        emit("cert", tls.get("certificate_path"))
        emit("key", tls.get("key_path"))
    break
PY
}

EX_FILE="$TMP/existing.tsv"
if [[ -f $CONFIG ]]; then
    read_existing >"$EX_FILE" || true
else
    : >"$EX_FILE"
fi

get_ex() { awk -F'\t' -v k="$1" '$1==k {sub(/^[^\t]*\t/, ""); print; exit}' "$EX_FILE"; }

EX_JSON_OK=$(get_ex json_ok || true)
EX_PORT=$(get_ex port || true)
EX_PASSWORD=$(get_ex password || true)
EX_OBFS_TYPE=$(get_ex obfs_type || true)
EX_OBFS_PASSWORD=$(get_ex obfs_password || true)
EX_MASQ=$(get_ex masquerade || true)
EX_SNI=$(get_ex sni || true)
EX_CERT=$(get_ex cert || true)
EX_KEY=$(get_ex key || true)

if [[ -f $CONFIG && $EX_JSON_OK != 1 && $FORCE -eq 0 ]]; then
    die "$CONFIG есть, но это не валидный JSON — разберитесь вручную или запустите с --force (будет бэкап)"
fi

PORT="${PORT_ARG:-${EX_PORT:-443}}"
[[ $PORT =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "--port: нужно число 1..65535"

gen_secret() { openssl rand -hex 24; }

# self-signed определяем по совпадению subject и issuer: не завязано на имя файла.
cert_selfsigned_file() {
    local file="$1" subject issuer
    [[ -r $file ]] || return 1
    subject=$(openssl x509 -in "$file" -noout -subject 2>/dev/null) || return 1
    issuer=$(openssl x509 -in "$file" -noout -issuer 2>/dev/null) || return 1
    [[ "${subject#subject=}" == "${issuer#issuer=}" ]]
}

PASSWORD="${PASSWORD_ARG:-${EX_PASSWORD:-}}"
[[ -n $PASSWORD ]] || { PASSWORD=$(gen_secret); NEW_PASSWORD=1; }
NEW_PASSWORD="${NEW_PASSWORD:-0}"

if [[ $MASQ_SET -eq 1 ]]; then
    MASQUERADE="$MASQ_ARG"
else
    MASQUERADE="${EX_MASQ:-https://www.microsoft.com/}"
fi
case "$MASQUERADE" in
    none|off|"") MASQUERADE="" ;;
    file://*) ;;
    http://*|https://*) ;;
    *) die "--masquerade: ожидается https://..., file:///path или none" ;;
esac

OBFS_TYPE="${OBFS_ARG:-${EX_OBFS_TYPE:-}}"
if [[ -n $OBFS_TYPE && $OBFS_TYPE != "salamander" ]]; then
    die "неизвестный obfs: $OBFS_TYPE"
fi
OBFS_PASSWORD="${OBFS_PASSWORD_ARG:-${EX_OBFS_PASSWORD:-}}"
if [[ -n $OBFS_TYPE && -z $OBFS_PASSWORD ]]; then
    OBFS_PASSWORD=$(gen_secret)
fi

# --- TLS: решаем режим и пути ------------------------------------------------
if [[ $CERT_MODE == auto ]]; then
    if [[ -n $EX_CERT && -n $EX_KEY && -r $EX_CERT && -r $EX_KEY ]]; then
        # --force перевыпускает только self-signed: настоящий сертификат не трогаем.
        if [[ $FORCE -eq 1 ]] && cert_selfsigned_file "$EX_CERT"; then
            CERT_MODE="selfsigned"
        else
            CERT_MODE="keep"
        fi
    else
        CERT_MODE="selfsigned"
    fi
fi

CERT_PATH="${CERT_ARG:-}"
KEY_PATH="${KEY_ARG:-}"

if [[ $CERT_MODE == keep ]]; then
    CERT_PATH="$EX_CERT"
    KEY_PATH="$EX_KEY"
elif [[ $CERT_MODE == none ]]; then
    [[ -n $CERT_PATH && -n $KEY_PATH ]] || die "--cert-mode none требует --cert и --key"
    [[ -r $CERT_PATH ]] || die "сертификат не читается: $CERT_PATH"
    [[ -r $KEY_PATH ]] || die "ключ не читается: $KEY_PATH"
elif [[ $CERT_MODE == acme ]]; then
    CERT_PATH="$CERT_DIR/fullchain.pem"
    KEY_PATH="$CERT_DIR/privkey.pem"
else
    CERT_PATH="$CERT_DIR/fullchain.pem"
    KEY_PATH="$CERT_DIR/privkey.pem"
fi

SNI=""
case "$CERT_MODE" in
    acme) [[ -n $DOMAIN ]] && SNI="$DOMAIN" ;;
    selfsigned|keep|none) SNI="${DOMAIN:-${EX_SNI:-}}" ;;
esac

# --- сервис: от какого пользователя работает unit ---------------------------
SVC_UNIT="/etc/systemd/system/sing-box.service"
svc_user() {
    local user=""
    if command -v systemctl >/dev/null && systemctl cat sing-box.service >/dev/null 2>&1; then
        user=$(systemctl show -p User --value sing-box.service 2>/dev/null || true)
    fi
    if [[ -z $user ]]; then
        local unit=""
        for unit in /etc/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service /lib/systemd/system/sing-box.service; do
            [[ -f $unit ]] || continue
            user=$(awk -F= '/^User=/ {print $2; exit}' "$unit")
            [[ -n $user ]] && break
        done
    fi
    printf '%s' "${user:-root}"
}

SVC_USER=$(svc_user)

# --- права: конфиг с паролем не должен быть читаем всем ---------------------
apply_secret_mode() {
    local path="$1" mode="$2"
    [[ -f $path ]] || return 0
    if [[ $SVC_USER == root ]]; then
        chown root:root "$path"
        chmod "$mode" "$path"
    else
        chmod 640 "$path"
        if getent group "$SVC_USER" >/dev/null 2>&1; then
            chown root:"$SVC_USER" "$path"
        else
            chown root:root "$path"
        fi
    fi
}

# --- генерация конфига -------------------------------------------------------
build_config() {
    local out="$1"
    HY2_OUT="$out" \
    HY2_EXISTING="$CONFIG" \
    HY2_PORT="$PORT" \
    HY2_TAG="$TAG" \
    HY2_LISTEN="$LISTEN" \
    HY2_PASSWORD="$PASSWORD" \
    HY2_OBFS_TYPE="$OBFS_TYPE" \
    HY2_OBFS_PASSWORD="$OBFS_PASSWORD" \
    HY2_SNI="$SNI" \
    HY2_CERT="$CERT_PATH" \
    HY2_KEY="$KEY_PATH" \
    HY2_MASQUERADE="$MASQUERADE" \
    python3 - <<'PY'
import json, os

env = os.environ
out_path = env["HY2_OUT"]
existing = env.get("HY2_EXISTING", "")
port = int(env["HY2_PORT"])
tag = env["HY2_TAG"]
pw = env["HY2_PASSWORD"]

cfg = {}
if existing and os.path.isfile(existing):
    try:
        with open(existing, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            cfg = loaded
    except ValueError:
        cfg = {}

# Не навязываем свой log, если он уже настроен.
if not isinstance(cfg.get("log"), dict):
    cfg["log"] = {"level": "warn", "timestamp": True}

tls = {
    "enabled": True,
    "alpn": ["h3"],
    "certificate_path": env["HY2_CERT"],
    "key_path": env["HY2_KEY"],
}
if env.get("HY2_SNI"):
    tls["server_name"] = env["HY2_SNI"]

inbound = {
    "type": "hysteria2",
    "tag": tag,
    "listen": env.get("HY2_LISTEN", "::"),
    "listen_port": port,
    "ignore_client_bandwidth": True,
    "users": [{"name": "default", "password": pw}],
    "tls": tls,
}

opw = env.get("HY2_OBFS_PASSWORD", "")
if env.get("HY2_OBFS_TYPE") and opw:
    inbound["obfs"] = {"type": env["HY2_OBFS_TYPE"], "password": opw}

masq = env.get("HY2_MASQUERADE", "")
if masq.startswith("file://"):
    inbound["masquerade"] = {"type": "file", "directory": masq[len("file://"):]}
elif masq:
    inbound["masquerade"] = {"type": "proxy", "url": masq, "rewrite_host": True}

inbounds = [i for i in (cfg.get("inbounds") or []) if isinstance(i, dict)]
inbounds = [
    i for i in inbounds
    if i.get("tag") != tag and not (i.get("type") == "hysteria2" and i.get("listen_port") == port)
]
inbounds.append(inbound)
cfg["inbounds"] = inbounds

if not cfg.get("outbounds"):
    cfg["outbounds"] = [{"type": "direct"}]

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
    python3 -m json.tool "$out" >/dev/null || die "сгенерированный конфиг не проходит json.tool"
}

# --- сертификаты -------------------------------------------------------------
cert_valid_week() {
    [[ -s $1 && -s $2 ]] || return 1
    openssl x509 -checkend 604800 -noout -in "$1" >/dev/null 2>&1
}

make_selfsigned() {
    local dir="$1" cn="$2" quiet="${3:-0}" san=""
    mkdir -p "$dir"
    san="IP:$PUBLIC_IP"
    if [[ -n $DOMAIN ]]; then
        san="$san,DNS:$DOMAIN"
    fi
    if cert_valid_week "$dir/fullchain.pem" "$dir/privkey.pem" && [[ $FORCE -eq 0 ]]; then
        ok "self-signed сертификат ещё валиден — переиспользую"
        return 0
    fi
    [[ $quiet -eq 1 ]] || info "выпускаю self-signed сертификат (EC P-256, SAN: $san)"
    # Ed25519 не годится: клиенты sing-box по умолчанию парротят Chrome, а он его не предлагает.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 365 -nodes \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
        -subj "/CN=$cn" \
        -addext "subjectAltName=$san" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 \
        || die "openssl не смог выпустить сертификат"
    chmod 600 "$dir/privkey.pem"
    chmod 644 "$dir/fullchain.pem"
    CERT_ROTATED=1
    [[ $quiet -eq 1 ]] || ok "сертификат: $dir/fullchain.pem (действует 365 дней, клиенту нужен insecure=1)"
}

acme_bin() {
    if command -v acme.sh >/dev/null; then
        command -v acme.sh
    elif [[ -x ${HOME}/.acme.sh/acme.sh ]]; then
        printf '%s' "${HOME}/.acme.sh/acme.sh"
    else
        return 1
    fi
}

ensure_acme() {
    local acme name
    if ! acme=$(acme_bin); then
        info "ставлю acme.sh"
        command -v curl >/dev/null || die "для acme.sh нужен curl"
        local installer="$TMP/acme-install.sh"
        curl -fsSL --max-time 60 https://get.acme.sh -o "$installer" || die "не скачался acme.sh"
        if [[ -n $ACME_EMAIL_ARG ]]; then
            sh "$installer" "email=$ACME_EMAIL_ARG" >/dev/null || die "acme.sh не установился"
        else
            sh "$installer" >/dev/null || die "acme.sh не установился"
        fi
        acme=$(acme_bin) || die "acme.sh установился, но не найден в PATH"
    fi

    name="${DOMAIN:-$PUBLIC_IP}"
    local issue=(--issue -d "$name" --server letsencrypt)
    if [[ -n $ACME_WEBROOT_ARG ]]; then
        issue+=(--webroot "$ACME_WEBROOT_ARG")
    else
        issue+=(--standalone)
    fi
    if [[ -z $DOMAIN ]]; then
        # Let's Encrypt выдаёт сертификаты на IP только в профиле shortlived (~6 дней).
        issue+=(--cert-profile shortlived --days 3)
    fi
    [[ -n $ACME_EMAIL_ARG ]] && issue+=(-m "$ACME_EMAIL_ARG")

    info "запрашиваю сертификат Let's Encrypt для $name"
    "$acme" "${issue[@]}" >&2 || die "acme.sh --issue не смог выпустить сертификат (порт 80 занят? нужен --acme-webroot)"

    mkdir -p "$CERT_DIR"
    # acme.sh переписывает файлы от root — после продления права надо вернуть,
    # иначе сервис под пользователем sing-box не прочитает ключ.
    local reload="systemctl restart sing-box"
    if [[ $SVC_USER != root ]]; then
        reload="chown root:$SVC_USER $CERT_DIR/privkey.pem $CERT_DIR/fullchain.pem; chmod 640 $CERT_DIR/privkey.pem; chmod 644 $CERT_DIR/fullchain.pem; $reload"
    fi
    "$acme" --install-cert -d "$name" \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "$reload" >&2 \
        || die "acme.sh --install-cert не смог разложить сертификат"
    chmod 600 "$CERT_DIR/privkey.pem"
    chmod 644 "$CERT_DIR/fullchain.pem"
    ok "сертификат разложен в $CERT_DIR (продление — cron acme.sh)"
}

prepare_certs() {
    case "$CERT_MODE" in
        selfsigned)
            if [[ $DRY_RUN -eq 1 ]]; then
                make_selfsigned "$TMP" "dry-run" 1 >/dev/null
                CHECK_CERT="$TMP/fullchain.pem"
                CHECK_KEY="$TMP/privkey.pem"
            else
                make_selfsigned "$CERT_DIR" "${DOMAIN:-$PUBLIC_IP}"
            fi
            ;;
        acme)
            if [[ $DRY_RUN -eq 1 ]]; then
                warn "dry-run: сертификат Let's Encrypt не запрашивается, проверка идёт на временном self-signed"
                make_selfsigned "$TMP" "dry-run" 1 >/dev/null
                CHECK_CERT="$TMP/fullchain.pem"
                CHECK_KEY="$TMP/privkey.pem"
            else
                ensure_acme
            fi
            ;;
        keep)
            ok "использую существующий сертификат: $CERT_PATH"
            ;;
        none)
            ok "использую внешний сертификат: $CERT_PATH"
            ;;
    esac
}

# --- конфиг: сборка, проверка, установка -------------------------------------
install_sing_box() {
    command -v sing-box >/dev/null && { ok "sing-box уже установлен: $(sing-box version | head -1)"; return 0; }
    info "sing-box не найден — ставлю официальным установщиком"
    command -v curl >/dev/null || die "для установки нужен curl"
    local installer="$TMP/sing-box-install.sh"
    curl -fsSL --max-time 60 https://sing-box.app/install.sh -o "$installer" \
        || die "не скачался установщик sing-box"
    sh "$installer" >&2 || die "установщик sing-box вернул ошибку"
    command -v sing-box >/dev/null || die "sing-box не появился в PATH после установки"
    ok "sing-box установлен: $(sing-box version | head -1)"
}

check_config() {
    local file="$1" target="$1"
    if [[ -n $CHECK_CERT && -n $CHECK_KEY ]]; then
        target="$TMP/config.check.json"
        python3 - "$file" "$target" "$CHECK_CERT" "$CHECK_KEY" <<'PY'
import json, sys

src, dst, cert, key = sys.argv[1:5]
with open(src, encoding="utf-8") as handle:
    cfg = json.load(handle)
for inbound in cfg.get("inbounds") or []:
    tls = inbound.get("tls") if isinstance(inbound, dict) else None
    if isinstance(tls, dict):
        tls["certificate_path"] = cert
        tls["key_path"] = key
with open(dst, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
PY
    fi
    if command -v sing-box >/dev/null; then
        sing-box check -c "$target" >&2 || die "sing-box check не принял конфиг: $file"
        ok "sing-box check: конфиг валиден"
    elif [[ $DRY_RUN -eq 1 ]]; then
        warn "sing-box не установлен — проверка конфига пропущена (JSON уже провалидирован json.tool)"
    else
        die "sing-box отсутствует, проверить конфиг нечем"
    fi
}

write_config() {
    local src="$1"
    mkdir -p "$(dirname "$CONFIG")"
    if [[ -f $CONFIG ]] && cmp -s "$src" "$CONFIG"; then
        ok "конфиг не изменился: $CONFIG"
        return 1
    fi
    local backup=""
    if [[ -f $CONFIG ]]; then
        backup="/root/vpn-backup-$(date +%Y%m%d-%H%M%S)"
        install -d -m 700 "$backup"
        cp -a "$CONFIG" "$backup/config.json"
        if [[ -d $CERT_DIR ]]; then
            cp -a "$CERT_DIR" "$backup/certs"
        fi
        ok "бэкап: $backup"
    fi
    install -m 600 "$src" "$CONFIG"
    apply_secret_mode "$CONFIG" 600
    ok "конфиг записан: $CONFIG"
    return 0
}

open_ufw() {
    [[ $NO_UFW -eq 1 ]] && { warn "ufw не трогаю (--no-ufw)"; return 0; }
    command -v ufw >/dev/null || { warn "ufw не установлен — откройте ${PORT}/udp в своём файрволе"; return 0; }
    if ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
        warn "ufw неактивен — правило не добавлено (не забывайте про облачный firewall)"
        return 0
    fi
    ufw allow "${PORT}/udp" comment 'hysteria2 (sing-box)' >/dev/null 2>&1 \
        || ufw allow "${PORT}/udp" >/dev/null 2>&1 \
        || { warn "ufw не принял правило для ${PORT}/udp"; return 0; }
    ok "ufw: разрешён ${PORT}/udp"
}

sing_box_path() {
    local candidate
    for candidate in /usr/bin/sing-box /usr/local/bin/sing-box /usr/sbin/sing-box; do
        [[ -x $candidate ]] && { printf '%s' "$candidate"; return 0; }
    done
    command -v sing-box
}

# Сертификаты должны читаться пользователем сервиса, иначе handshake падает на старте.
fix_cert_perms() {
    local dir
    dir=$(dirname "$CERT_PATH")
    case "$CERT_PATH" in
        "$CERT_DIR"/*) ;;
        *) warn "сертификат вне $CERT_DIR — проверьте, что пользователь $SVC_USER читает $KEY_PATH"; return 0 ;;
    esac
    if [[ $SVC_USER == root ]]; then
        chmod 755 "$dir" 2>/dev/null || true
        chmod 644 "$CERT_PATH" 2>/dev/null || true
        chmod 600 "$KEY_PATH" 2>/dev/null || true
    else
        getent group "$SVC_USER" >/dev/null 2>&1 || return 0
        chmod 750 "$dir" 2>/dev/null || true
        chown root:"$SVC_USER" "$dir" "$CERT_PATH" "$KEY_PATH" 2>/dev/null || true
        chmod 644 "$CERT_PATH" 2>/dev/null || true
        chmod 640 "$KEY_PATH" 2>/dev/null || true
    fi
}

ensure_unit() {
    if systemctl cat sing-box.service >/dev/null 2>&1; then
        ok "systemd unit уже есть (User=${SVC_USER})"
        return 0
    fi
    [[ -d /run/systemd/system ]] || { warn "systemd не запущен — unit не ставлю"; return 0; }
    if ! id -u sing-box >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin sing-box \
            || die "не удалось создать пользователя sing-box"
    fi
    local bin
    bin=$(sing_box_path)
    install -d -m 755 /etc/sing-box
    install -d -m 750 -o root -g sing-box "$CERT_DIR" 2>/dev/null || install -d -m 755 "$CERT_DIR"

    cat >"$SVC_UNIT" <<UNIT
[Unit]
Description=sing-box service (Hysteria2)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
User=sing-box
StateDirectory=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStart=$bin -D /var/lib/sing-box -C /etc/sing-box run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$SVC_UNIT"
    SVC_USER="sing-box"
    systemctl daemon-reload
    ok "systemd unit установлен: $SVC_UNIT"
}

restart_service() {
    [[ $NO_SERVICE -eq 1 ]] && { warn "сервис не перезапускаю (--no-service)"; return 0; }
    [[ -d /run/systemd/system ]] || { warn "systemd не запущен — запустите sing-box вручную"; return 0; }
    systemctl enable sing-box >/dev/null 2>&1 || true
    if ! systemctl restart sing-box; then
        die "sing-box не перезапустился: journalctl -u sing-box -e"
    fi
    sleep 1
    if ! systemctl is-active --quiet sing-box; then
        die "sing-box не активен: journalctl -u sing-box -e"
    fi
    ok "sing-box активен"
    if command -v ss >/dev/null && ss -lun 2>/dev/null | grep -q ":$PORT\b"; then
        ok "UDP ${PORT} слушается"
    fi
}

# Порт считается занятым, только если его слушает не наш sing-box:
# иначе идемпотентный повторный запуск упирался бы в собственный сервис.
port_is_busy() {
    local line
    command -v ss >/dev/null || return 1
    line=$(ss -lunp 2>/dev/null | awk -v p=":$PORT\$" '$1 ~ /^UNCONN/ && $4 ~ p')
    [[ -n $line ]] || return 1
    grep -q 'sing-box' <<<"$line" && return 1
    return 0
}

uri_escape() {
    printf '%s' "$1" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'
}

cert_is_selfsigned() { cert_selfsigned_file "$CERT_PATH"; }

build_link() {
    local scheme="hysteria2" query="" frag
    if [[ $CERT_MODE == selfsigned ]]; then
        query="insecure=1"
    elif [[ $CERT_MODE == keep || $CERT_MODE == none ]] && cert_is_selfsigned; then
        query="insecure=1"
    fi
    if [[ -n $SNI ]]; then
        query="${query:+$query&}sni=$(uri_escape "$SNI")"
    fi
    if [[ -n $OBFS_TYPE ]]; then
        query="${query:+$query&}obfs=$(uri_escape "$OBFS_TYPE")"
        query="${query:+$query&}obfs-password=$(uri_escape "$OBFS_PASSWORD")"
    fi
    frag=$(uri_escape "Hysteria2-${HOST_FOR_LINK}")
    if [[ -n $query ]]; then
        printf '%s://%s@%s:%s/?%s#%s\n' "$scheme" "$(uri_escape "$PASSWORD")" \
            "$HOST_IN_LINK" "$PORT" "$query" "$frag"
    else
        printf '%s://%s@%s:%s/#%s\n' "$scheme" "$(uri_escape "$PASSWORD")" \
            "$HOST_IN_LINK" "$PORT" "$frag"
    fi
}

# --- основной сценарий -------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    install_sing_box
    SVC_USER=$(svc_user)
else
    info "dry-run: система не меняется"
fi

prepare_certs
SVC_USER=$(svc_user)

CFG_OUT="$TMP/config.json"
build_config "$CFG_OUT"
check_config "$CFG_OUT"

if [[ $DRY_RUN -eq 1 ]]; then
    info "собранный конфиг: $CFG_OUT (каталог сохранён для проверки)"
    [[ -n $CHECK_CERT ]] && info "копия для sing-box check (временные сертификаты): $TMP/config.check.json"
    info "был бы записан в: $CONFIG (режим 600/640, пароль внутри)"
    [[ $NEW_PASSWORD -eq 1 ]] && warn "пароль сгенерирован и больше нигде не сохранится"
    build_link
    exit 0
fi

if port_is_busy && [[ $FORCE -eq 0 ]]; then
    die "UDP-порт $PORT уже занят (ss -lunp | grep :$PORT); другой порт: --port 8443, или --force"
fi

if [[ $NO_SERVICE -eq 0 ]]; then
    ensure_unit
fi
fix_cert_perms
restart_needed=0
if write_config "$CFG_OUT"; then
    restart_needed=1
fi
if [[ $CERT_ROTATED -eq 1 ]]; then
    info "сертификат перевыпущен — сервис нужно перезапустить"
    restart_needed=1
fi
open_ufw
if [[ $restart_needed -eq 1 ]]; then
    restart_service
else
    info "конфиг не менялся — перезапуск не нужен"
    if [[ -d /run/systemd/system ]] && ! systemctl is-active --quiet sing-box; then
        restart_service
    fi
fi

say ""
ok "готово. Порт: ${PORT}/udp, inbound: $TAG, TLS: $CERT_MODE"
say "Клиенты: Hiddify / NekoBox / Streisand — импорт по ссылке ниже."
say "Проверка снаружи: nmap -sU -p $PORT $HOST_FOR_LINK (open|filtered) и реальное подключение клиентом."
say "Ссылка печатается один раз:"
build_link
