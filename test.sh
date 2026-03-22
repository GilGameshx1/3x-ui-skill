#!/bin/bash
# 3x-ui-setup Skill Test Script
# Version: 2.0.0
#
# Этот скрипт проверяет корректность установки и работы навыка 3x-ui-setup

# Не используем set -e, так как хотим продолжить после неудачных тестов

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SKILL_NAME="3x-ui-setup"
SKILL_DIR="${HOME}/.qwen/skills/${SKILL_NAME}"

# Счётчики тестов
TESTS_PASSED=0
TESTS_FAILED=0

# Функция для запуска теста
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -ne "${CYAN}Тест: ${test_name}... ${NC}"
    
    if eval "$test_command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Функция для запуска теста с ожиданием результата
run_test_with_output() {
    local test_name="$1"
    local test_command="$2"
    
    echo -e "${CYAN}Тест: ${test_name}${NC}"
    echo "-------------------------------------------"
    
    if eval "$test_command" 2>&1; then
        echo -e "${GREEN}✓ Тест пройден${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ Тест не пройден${NC}"
        ((TESTS_FAILED++))
    fi
    echo ""
}

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     3x-ui-setup Skill — Тестирование                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка 1: Директория скила существует
run_test "Директория скила существует" "[ -d '${SKILL_DIR}' ]"

# Проверка 2: SKILL.md существует
run_test "SKILL.md существует" "[ -f '${SKILL_DIR}/SKILL.md' ]"

# Проверка 3: QWEN.md существует
run_test "QWEN.md существует" "[ -f '${SKILL_DIR}/QWEN.md' ]"

# Проверка 4: README.md существует
run_test "README.md существует" "[ -f '${SKILL_DIR}/README.md' ]"

# Проверка 5: install.sh существует
run_test "install.sh существует" "[ -f '${SKILL_DIR}/install.sh' ]"

# Проверка 6: install.sh исполняемый
run_test "install.sh исполняемый" "[ -x '${SKILL_DIR}/install.sh' ]"

# Проверка 7: rollback.sh существует
run_test "rollback.sh существует" "[ -f '${SKILL_DIR}/rollback.sh' ]"

# Проверка 8: rollback.sh исполняемый
run_test "rollback.sh исполняемый" "[ -x '${SKILL_DIR}/rollback.sh' ]"

# Проверка 9: backup-db.sh существует
run_test "backup-db.sh существует" "[ -f '${SKILL_DIR}/backup-db.sh' ]"

# Проверка 10: backup-db.sh исполняемый
run_test "backup-db.sh исполняемый" "[ -x '${SKILL_DIR}/backup-db.sh' ]"

# Проверка 11: restore-db.sh существует
run_test "restore-db.sh существует" "[ -f '${SKILL_DIR}/restore-db.sh' ]"

# Проверка 12: restore-db.sh исполняемый
run_test "restore-db.sh исполняемый" "[ -x '${SKILL_DIR}/restore-db.sh' ]"

# Проверка 13: Директория references существует
run_test "Директория references существует" "[ -d '${SKILL_DIR}/references' ]"

# Проверка 14: vless-tls.md существует
run_test "vless-tls.md существует" "[ -f '${SKILL_DIR}/references/vless-tls.md' ]"

# Проверка 15: fallback-nginx.md существует
run_test "fallback-nginx.md существует" "[ -f '${SKILL_DIR}/references/fallback-nginx.md' ]"

# Проверка 16: LICENSE существует
run_test "LICENSE существует" "[ -f '${SKILL_DIR}/LICENSE' ]"

# Проверка 17: .gitignore существует
run_test ".gitignore существует" "[ -f '${SKILL_DIR}/.gitignore' ]"

# Проверка 18: CHANGELOG.md существует
run_test "CHANGELOG.md существует" "[ -f '${SKILL_DIR}/CHANGELOG.md' ]"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Проверка 19: Содержимое SKILL.md (проверка ключевых разделов)
run_test_with_output "Проверка структуры SKILL.md" "
    grep -q 'PART 0: Information Collection' '${SKILL_DIR}/SKILL.md' &&
    grep -q 'PART 1: Server Hardening' '${SKILL_DIR}/SKILL.md' &&
    grep -q 'PART 2: VPN Installation' '${SKILL_DIR}/SKILL.md' &&
    grep -q 'SQLite3' '${SKILL_DIR}/SKILL.md' &&
    grep -q 'Guide File' '${SKILL_DIR}/SKILL.md'
"

# Проверка 20: Содержимое QWEN.md (проверка на русском языке)
run_test_with_output "Проверка локализации QWEN.md" "
    grep -q 'Конфигурация активации' '${SKILL_DIR}/QWEN.md'
"

# Проверка 21: Содержимое README.md (проверка на русском языке)
run_test_with_output "Проверка локализации README.md" "
    grep -q 'Быстрый старт' '${SKILL_DIR}/README.md'
"

# Проверка 22: Проверка install.sh (помощь)
run_test_with_output "Проверка help в install.sh" "
    bash '${SKILL_DIR}/install.sh' --help 2>&1 | grep -q 'Справка'
"

# Проверка 23: Проверка зависимостей
run_test_with_output "Проверка зависимостей" "
    bash '${SKILL_DIR}/install.sh' check 2>&1 | grep -q 'Все зависимости установлены'
"

# Проверка 24: rollback.sh имеет правильную структуру
run_test_with_output "Проверка структуры rollback.sh" "
    grep -q 'Removing 3x-ui' '${SKILL_DIR}/rollback.sh' &&
    grep -q 'Restore SSH' '${SKILL_DIR}/rollback.sh'
"

# Проверка 25: backup-db.sh имеет правильную структуру
run_test_with_output "Проверка структуры backup-db.sh" "
    grep -q 'Creating database backup' '${SKILL_DIR}/backup-db.sh' &&
    grep -q 'SQLite3' '${SKILL_DIR}/backup-db.sh'
"

# Итоги
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Результаты тестов                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Пройдено: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Не пройдено: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [ ${TESTS_FAILED} -eq 0 ]; then
    echo -e "${GREEN}✓ Все тесты пройдены успешно!${NC}"
    echo ""
    echo -e "${YELLOW}Скил готов к использованию.${NC}"
    exit 0
else
    echo -e "${RED}✗ Некоторые тесты не пройдены.${NC}"
    echo ""
    echo -e "${YELLOW}Рекомендуется переустановить скил:${NC}"
    echo -e "  ${GREEN}bash ${SKILL_DIR}/install.sh update${NC}"
    exit 1
fi
