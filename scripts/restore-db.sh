#!/bin/bash
# 3x-ui SQLite3 Database Restore Script
# Version: 2.0.0
#
# This script restores a 3x-ui SQLite3 database from backup.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DB_PATH="/etc/x-ui/x-ui.db"
BACKUP_DIR="/root/x-ui-backups"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     3x-ui SQLite3 Database Restore Script              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0 [backup-file]"
    exit 1
fi

# Get backup file
if [ -n "$1" ]; then
    BACKUP_FILE="$1"
else
    echo -e "${YELLOW}Available backups:${NC}"
    echo ""
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        echo -e "${RED}No backups found in $BACKUP_DIR${NC}"
        exit 1
    fi
    
    ls -lh ${BACKUP_DIR}/x-ui.db.backup.*
    echo ""
    read -p "Enter backup file to restore: " BACKUP_FILE
    
    # Auto-add path if not provided
    if [[ ! "$BACKUP_FILE" =~ ^/ ]]; then
        BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
    fi
fi

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo -e "${RED}ERROR: Backup file not found: $BACKUP_FILE${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Backup file: $BACKUP_FILE${NC}"
echo -e "${YELLOW}Target: $DB_PATH${NC}"
echo ""

# Confirm restore
echo -e "${RED}⚠️  WARNING: This will overwrite the current database!${NC}"
echo ""
read -p "Are you sure you want to continue? (type 'YES' to confirm): " confirm

if [ "$confirm" != "YES" ]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Starting restore...${NC}"
echo ""

# Step 1: Create backup of current database
echo -e "${YELLOW}[1/5] Backing up current database...${NC}"
if [ -f "$DB_PATH" ]; then
    CURRENT_BACKUP="${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$DB_PATH" "$CURRENT_BACKUP"
    echo -e "${GREEN}✓ Current database backed up to: $CURRENT_BACKUP${NC}"
else
    echo -e "${YELLOW}! No current database found, skipping backup${NC}"
fi

# Step 2: Stop 3x-ui
echo ""
echo -e "${YELLOW}[2/5] Stopping 3x-ui panel...${NC}"
sudo x-ui stop
echo -e "${GREEN}✓ 3x-ui stopped${NC}"

# Step 3: Restore database
echo ""
echo -e "${YELLOW}[3/5] Restoring database...${NC}"

if [[ "$BACKUP_FILE" =~ \.gz$ ]]; then
    zcat "$BACKUP_FILE" > "$DB_PATH"
    echo -e "${GREEN}✓ Database restored (from compressed backup)${NC}"
else
    cp "$BACKUP_FILE" "$DB_PATH"
    echo -e "${GREEN}✓ Database restored${NC}"
fi

# Step 4: Verify integrity
echo ""
echo -e "${YELLOW}[4/5] Verifying database integrity...${NC}"

if sqlite3 "$DB_PATH" "PRAGMA integrity_check;" | grep -q "ok"; then
    echo -e "${GREEN}✓ Database integrity check passed${NC}"
else
    echo -e "${RED}✗ Database integrity check failed!${NC}"
    echo "Restoring previous database..."
    cp "$CURRENT_BACKUP" "$DB_PATH"
    echo -e "${YELLOW}Previous database restored${NC}"
    exit 1
fi

# Step 5: Start 3x-ui
echo ""
echo -e "${YELLOW}[5/5] Starting 3x-ui panel...${NC}"
sudo x-ui start
echo -e "${GREEN}✓ 3x-ui started${NC}"

# Verify
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Database restore completed successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# Check panel status
echo -e "${YELLOW}Panel status:${NC}"
sudo x-ui status

echo ""
echo -e "${GREEN}Database restored from: $BACKUP_FILE${NC}"
echo -e "${YELLOW}Previous database saved to: $CURRENT_BACKUP${NC}"
echo ""
