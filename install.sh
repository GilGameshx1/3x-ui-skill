#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SKILL_NAME="3x-ui-setup"
SKILL_DIR="${HOME}/.qwen/skills/${SKILL_NAME}"
REPO_URL="https://github.com/GilGameshx1/3x-ui-skill"

# Функция для проверки зависимостей
check_dependencies() {
    echo -e "${CYAN}Проверка зависимостей...${NC}"
    
    local missing=()
    
    # Проверка curl
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    # Проверка tar
    if ! command -v tar &> /dev/null; then
        missing+=("tar")
    fi
    
    # Проверка git (опционально)
    if ! command -v git &> /dev/null; then
        echo -e "${YELLOW}! git не найден, будет использован curl${NC}"
    fi
    
    # Если есть отсутствующие зависимости
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}✗ Отсутствуют необходимые зависимости:${NC}"
        for dep in "${missing[@]}"; do
            echo -e "  - ${RED}${dep}${NC}"
        done
        echo ""
        echo -e "${YELLOW}Установите их командой:${NC}"
        echo -e "  ${GREEN}apt update && apt install -y ${missing[*]}${NC}"
        echo ""
        exit 1
    fi
    
    echo -e "${GREEN}✓ Все зависимости установлены${NC}"
}

# Функция для обновления скила
update_skill() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Обновление 3x-ui-setup Skill                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [ ! -d "${SKILL_DIR}" ]; then
        echo -e "${YELLOW}Скил не установлен. Выполняется установка...${NC}"
        install_skill
        return
    fi
    
    echo -e "${YELLOW}Обновление скила...${NC}"
    rm -rf "${SKILL_DIR}"
    mkdir -p "${SKILL_DIR}"
    
    download_skill
    
    echo ""
    echo -e "${GREEN}✓ Скил успешно обновлён!${NC}"
    echo ""
    echo -e "${YELLOW}Расположение: ${SKILL_DIR}${NC}"
}

# Функция для установки скила
install_skill() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     3x-ui-setup Skill Installer for Qwen Code         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверка зависимостей
    check_dependencies
    
    echo ""
    
    # Проверка ~/.qwen/skills/
    if [ ! -d "${HOME}/.qwen/skills" ]; then
        echo -e "${YELLOW}Создание ${HOME}/.qwen/skills/ ...${NC}"
        mkdir -p "${HOME}/.qwen/skills"
    fi
    
    # Проверка, установлен ли скил
    if [ -d "${SKILL_DIR}" ]; then
        echo -e "${YELLOW}Скил уже установлен в ${SKILL_DIR}${NC}"
        echo -e "${YELLOW}Обновление...${NC}"
        rm -rf "${SKILL_DIR}"
    fi
    
    # Создание директории скила
    mkdir -p "${SKILL_DIR}"
    
    echo -e "${BLUE}Загрузка файлов скила...${NC}"
    
    download_skill
}

# Функция для загрузки скила
download_skill() {
    # Попытка git clone, fallback на curl
    if command -v git &> /dev/null; then
        echo -e "${GREEN}✓ Использование git для загрузки${NC}"
        TMPDIR=$(mktemp -d)
        if git clone --depth 1 "${REPO_URL}.git" "${TMPDIR}" 2>/dev/null; then
            # Копирование всех файлов из корня репозитория в директорию скила
            cp -r "${TMPDIR}"/. "${SKILL_DIR}/"
            rm -rf "${TMPDIR}"
        else
            echo -e "${RED}✗ Git clone не удался, пробуем curl...${NC}"
            rm -rf "${TMPDIR}"
            TMPDIR=$(mktemp -d)
            curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "${TMPDIR}"
            cp -r "${TMPDIR}/3x-ui-skill-main"/. "${SKILL_DIR}/"
            rm -rf "${TMPDIR}"
        fi
    else
        echo -e "${YELLOW}git не найден, загрузка через curl...${NC}"
        TMPDIR=$(mktemp -d)
        curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "${TMPDIR}"
        cp -r "${TMPDIR}/3x-ui-skill-main"/. "${SKILL_DIR}/"
        rm -rf "${TMPDIR}"
    fi
    
    echo ""
    echo -e "${GREEN}Установлено в: ${SKILL_DIR}${NC}"
    echo ""
    
    # Проверка установки
    if [ -f "${SKILL_DIR}/SKILL.md" ]; then
        echo -e "${GREEN}✓ Проверка: OK${NC}"
        echo ""
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                    Установка завершена                ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Использование:${NC} Откройте Qwen Code и скажите:"
        echo -e "  ${GREEN}\"Настрой VPN сервер на моём VPS\"${NC}"
        echo ""
        echo -e "${YELLOW}Скил активируется автоматически.${NC}"
    else
        echo -e "${RED}✗ ОШИБКА: Установка не удалась. SKILL.md не найден.${NC}"
        exit 1
    fi
}

# Отображение справки
show_help() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     3x-ui-setup Skill Installer — Справка              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Использование:"
    echo "  $0 [команда]"
    echo ""
    echo "Команды:"
    echo "  (без команды)  Установка скила (по умолчанию)"
    echo "  install        Установка скила"
    echo "  update         Обновление скила"
    echo "  check          Проверка зависимостей"
    echo "  help           Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $0                    # Установить скил"
    echo "  $0 update             # Обновить скил"
    echo "  $0 check              # Проверить зависимости"
    echo ""
}

# Основная логика
case "${1:-install}" in
    install)
        install_skill
        ;;
    update)
        update_skill
        ;;
    check)
        check_dependencies
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}✗ Неизвестная команда: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
