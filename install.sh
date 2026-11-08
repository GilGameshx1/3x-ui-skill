#!/usr/bin/env bash
# Установщик навыка 3x-ui-vpn для Hermes Agent (и любого агента, читающего SKILL.md).
#
#   ./install.sh              установить в ~/.hermes/skills/infrastructure/3x-ui-vpn
#   ./install.sh update       переустановить из репозитория
#   ./install.sh --dir PATH   поставить в произвольный каталог
#   ./install.sh check        только проверить зависимости
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/GilGameshx1/3x-ui-skill}"   # можно переопределить: локальный путь, fork
SKILL_NAME="3x-ui-vpn"
DEFAULT_DIR="${HERMES_SKILLS_DIR:-${HOME}/.hermes/skills}/infrastructure/${SKILL_NAME}"
TARGET_DIR="${SKILL_DIR:-$DEFAULT_DIR}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say() { printf '%b\n' "$*"; }

check_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v tar  >/dev/null || missing+=(tar)
    command -v python3 >/dev/null || missing+=(python3)
    if ((${#missing[@]})); then
        say "${RED}Не хватает: ${missing[*]}${NC}"
        say "  apt update && apt install -y ${missing[*]}"
        exit 1
    fi
    say "${GREEN}✓ зависимости на месте${NC}"
}

download() {
    local tmp; tmp=$(mktemp -d)
    if command -v git >/dev/null && git clone --depth 1 -q "$REPO_URL" "$tmp/repo" 2>/dev/null; then
        cp -a "$tmp/repo/." "$TARGET_DIR/"
    else
        curl -fsSL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "$tmp"
        cp -a "$tmp"/3x-ui-skill-main/. "$TARGET_DIR/"
    fi
    rm -rf "$tmp"
}

install_skill() {
    say "${CYAN}Установка ${SKILL_NAME} → ${TARGET_DIR}${NC}"
    mkdir -p "$TARGET_DIR"
    [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]] && { say "${YELLOW}каталог не пуст — перезаписываю файлы навыка${NC}"; }
    download
    [[ -f "$TARGET_DIR/SKILL.md" ]] || { say "${RED}SKILL.md не найден после установки${NC}"; exit 1; }
    chmod +x "$TARGET_DIR"/scripts/*.sh "$TARGET_DIR"/install.sh 2>/dev/null || true
    say "${GREEN}✓ готово${NC}"
    say ""
    say "Проверка целостности:"
    bash "$TARGET_DIR/scripts/check_no_secrets.sh" || say "${YELLOW}! в файлах навыка есть секреты — не публикуйте их${NC}"
    say ""
    say "Дальше просто скажите агенту: «настрой VPN на новом VPS» или «проверь, всё ли в порядке на сервере»."
}

case "${1:-install}" in
    install)   check_deps; install_skill ;;
    update)    check_deps; install_skill ;;
    check)     check_deps ;;
    --dir)     TARGET_DIR="${2:?нужен путь}"; check_deps; install_skill ;;
    help|-h|--help)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) say "${RED}Неизвестная команда: $1${NC}"; exit 1 ;;
esac
