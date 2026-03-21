#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SKILL_NAME="3x-ui-setup"
SKILL_DIR="${HOME}/.qwen/skills/${SKILL_NAME}"
REPO_URL="https://github.com/GilGameshx1/3x-ui-skill"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     3x-ui-setup Skill Installer for Qwen Code         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if ~/.qwen/skills/ exists
if [ ! -d "${HOME}/.qwen/skills" ]; then
    echo -e "${YELLOW}Creating ${HOME}/.qwen/skills/ ...${NC}"
    mkdir -p "${HOME}/.qwen/skills"
fi

# Check if skill already exists
if [ -d "${SKILL_DIR}" ]; then
    echo -e "${YELLOW}Skill already installed at ${SKILL_DIR}${NC}"
    echo -e "${YELLOW}Updating...${NC}"
    rm -rf "${SKILL_DIR}"
fi

# Create skill directory
mkdir -p "${SKILL_DIR}"

echo -e "${BLUE}Downloading skill files...${NC}"

# Try git clone first, fallback to curl
if command -v git &> /dev/null; then
    echo -e "${GREEN}✓ Using git for download${NC}"
    TMPDIR=$(mktemp -d)
    if git clone --depth 1 "${REPO_URL}.git" "${TMPDIR}" 2>/dev/null; then
        # Copy all files from repo root to skill directory
        cp -r "${TMPDIR}"/. "${SKILL_DIR}/"
        rm -rf "${TMPDIR}"
    else
        echo -e "${RED}✗ Git clone failed, trying curl...${NC}"
        rm -rf "${TMPDIR}"
        TMPDIR=$(mktemp -d)
        curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "${TMPDIR}"
        cp -r "${TMPDIR}/3x-ui-skill-main"/. "${SKILL_DIR}/"
        rm -rf "${TMPDIR}"
    fi
else
    echo -e "${YELLOW}git not found, downloading via curl...${NC}"
    TMPDIR=$(mktemp -d)
    curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "${TMPDIR}"
    cp -r "${TMPDIR}/3x-ui-skill-main"/. "${SKILL_DIR}/"
    rm -rf "${TMPDIR}"
fi

echo ""
echo -e "${GREEN}Installed to: ${SKILL_DIR}${NC}"
echo ""

# Verify installation
if [ -f "${SKILL_DIR}/SKILL.md" ]; then
    echo -e "${GREEN}✓ Verification: OK${NC}"
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    Installation Complete              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} Open Qwen Code and say:"
    echo -e "  ${GREEN}\"Set up a VPN server on my VPS\"${NC}"
    echo ""
    echo -e "${YELLOW}The skill will activate automatically.${NC}"
else
    echo -e "${RED}✗ ERROR: Installation failed. SKILL.md not found.${NC}"
    exit 1
fi
