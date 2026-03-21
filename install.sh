#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="3x-ui-setup"
SKILL_DIR="${HOME}/.qwen/skills/${SKILL_NAME}"
REPO_URL="https://github.com/GilGameshx1/3x-ui-skill"

echo "=== 3x-ui-setup skill installer for Qwen Code ==="
echo ""

# Check if ~/.qwen/skills/ exists
if [ ! -d "${HOME}/.qwen/skills" ]; then
    echo "Creating ${HOME}/.qwen/skills/ ..."
    mkdir -p "${HOME}/.qwen/skills"
fi

# Check if skill already exists
if [ -d "${SKILL_DIR}" ]; then
    echo "Skill already installed at ${SKILL_DIR}"
    echo "Updating..."
    rm -rf "${SKILL_DIR}"
fi

# Try git clone first, fallback to curl
if command -v git &> /dev/null; then
    echo "Cloning repository..."
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "${REPO_URL}.git" "${TMPDIR}" 2>/dev/null
    cp -r "${TMPDIR}/skill" "${SKILL_DIR}"
    rm -rf "${TMPDIR}"
else
    echo "git not found, downloading via curl..."
    TMPDIR=$(mktemp -d)
    curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz -C "${TMPDIR}"
    cp -r "${TMPDIR}/3x-ui-skill-main/skill" "${SKILL_DIR}"
    rm -rf "${TMPDIR}"
fi

echo ""
echo "Installed to: ${SKILL_DIR}"
echo ""

# Verify
if [ -f "${SKILL_DIR}/SKILL.md" ]; then
    echo "Verification: OK"
    echo ""
    echo "Usage: Open Qwen Code and say:"
    echo '  "Set up a VPN server on my VPS"'
    echo ""
    echo "The skill will activate automatically."
else
    echo "ERROR: Installation failed. SKILL.md not found."
    exit 1
fi
