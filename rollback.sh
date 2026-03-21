#!/bin/bash
# 3x-ui-setup Rollback Script
# Version: 2.0.0
# 
# This script removes all changes made by the 3x-ui-setup skill
# and restores the server to its original state.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║         3x-ui-setup ROLLBACK Script                    ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}⚠️  WARNING: This will remove all 3x-ui-setup changes!${NC}"
echo ""
echo "This script will:"
echo "  1. Stop and remove 3x-ui panel"
echo "  2. Remove the non-root user (if specified)"
echo "  3. Restore SSH to default configuration"
echo "  4. Disable UFW firewall"
echo "  5. Remove fail2ban"
echo "  6. Remove kernel hardening settings"
echo ""
echo -e "${YELLOW}Some manual cleanup will still be required:${NC}"
echo "  - SSH config entries (~/.ssh/config)"
echo "  - SSH keys (~/.ssh/*_key*)"
echo "  - Guide files (~/vpn-*-guide.md)"
echo ""

read -p "Are you sure you want to continue? (type 'YES' to confirm): " confirm

if [ "$confirm" != "YES" ]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Starting rollback...${NC}"
echo ""

# Step 1: Remove 3x-ui
echo -e "${YELLOW}[1/6] Removing 3x-ui panel...${NC}"
if [ -f /usr/local/x-ui/x-ui.sh ]; then
    sudo /usr/local/x-ui/x-ui.sh uninstall
    echo -e "${GREEN}✓ 3x-ui removed${NC}"
else
    echo -e "${YELLOW}! 3x-ui not found, skipping${NC}"
fi

# Step 2: Remove user
echo ""
echo -e "${YELLOW}[2/6] Remove non-root user?${NC}"
read -p "Enter username to remove (or press Enter to skip): " username

if [ -n "$username" ]; then
    if id "$username" &>/dev/null; then
        sudo userdel -r "$username" 2>/dev/null || true
        echo -e "${GREEN}✓ User '$username' removed${NC}"
    else
        echo -e "${YELLOW}! User '$username' not found${NC}"
    fi
else
    echo -e "${YELLOW}Skipped${NC}"
fi

# Step 3: Restore SSH
echo ""
echo -e "${YELLOW}[3/6] Restoring SSH configuration...${NC}"

# Backup current config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.rollback-backup

# Restore defaults
sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH
sudo systemctl restart sshd

echo -e "${GREEN}✓ SSH configuration restored${NC}"
echo -e "${YELLOW}! Original config backed up to: /etc/ssh/sshd_config.rollback-backup${NC}"

# Step 4: Disable firewall
echo ""
echo -e "${YELLOW}[4/6] Disabling UFW firewall...${NC}"

if command -v ufw &> /dev/null; then
    sudo ufw --force disable
    echo -e "${GREEN}✓ UFW disabled${NC}"
else
    echo -e "${YELLOW}! UFW not found, skipping${NC}"
fi

# Step 5: Remove fail2ban
echo ""
echo -e "${YELLOW}[5/6] Removing fail2ban...${NC}"

if command -v fail2ban-client &> /dev/null; then
    sudo apt remove -y fail2ban
    sudo apt autoremove -y
    echo -e "${GREEN}✓ fail2ban removed${NC}"
else
    echo -e "${YELLOW}! fail2ban not found, skipping${NC}"
fi

# Step 6: Remove kernel hardening
echo ""
echo -e "${YELLOW}[6/6] Removing kernel hardening...${NC}"

if [ -f /etc/sysctl.d/99-security.conf ]; then
    sudo rm /etc/sysctl.d/99-security.conf
    sudo sysctl -p /etc/sysctl.d/99-security.conf 2>/dev/null || true
    echo -e "${GREEN}✓ Kernel hardening removed${NC}"
else
    echo -e "${YELLOW}! Kernel hardening config not found${NC}"
fi

# Cleanup
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Rollback completed successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Manual cleanup required:${NC}"
echo ""
echo "1. Remove SSH config entries:"
echo "   Edit ~/.ssh/config and remove the server entry"
echo ""
echo "2. Remove SSH keys:"
echo "   rm ~/.ssh/*_key* 2>/dev/null"
echo ""
echo "3. Remove guide files:"
echo "   rm ~/vpn-*-guide.md 2>/dev/null"
echo ""
echo "4. Remove rollback script:"
echo "   rm $0"
echo ""

echo -e "${YELLOW}Server reboot recommended to ensure all changes take effect.${NC}"
read -p "Reboot now? (y/N): " reboot_confirm

if [ "$reboot_confirm" = "y" ]; then
    echo "Rebooting..."
    sudo reboot
fi
