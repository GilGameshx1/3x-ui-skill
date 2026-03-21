#!/bin/bash
# 3x-ui SQLite3 Database Backup Script
# Version: 2.0.0
#
# This script creates backups of the 3x-ui SQLite3 database
# and optionally uploads them to a safe location.

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
MAX_BACKUPS=10

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     3x-ui SQLite3 Database Backup Script               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Check if database exists
if [ ! -f "$DB_PATH" ]; then
    echo -e "${RED}ERROR: Database not found at $DB_PATH${NC}"
    exit 1
fi

# Create backup directory
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    echo -e "${GREEN}✓ Created backup directory: $BACKUP_DIR${NC}"
fi

# Create backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/x-ui.db.backup.${TIMESTAMP}"

echo -e "${YELLOW}[1/4] Creating database backup...${NC}"

# Verify database integrity before backup
echo -e "${YELLOW}[2/4] Verifying database integrity...${NC}"
if sqlite3 "$DB_PATH" "PRAGMA integrity_check;" | grep -q "ok"; then
    echo -e "${GREEN}✓ Database integrity check passed${NC}"
else
    echo -e "${RED}✗ Database integrity check failed!${NC}"
    echo "The database may be corrupted. Backup aborted."
    exit 1
fi

# Copy database
echo -e "${YELLOW}[3/4] Copying database...${NC}"
cp "$DB_PATH" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"

# Compress backup
echo -e "${YELLOW}[4/4] Compressing backup...${NC}"
if command -v gzip &> /dev/null; then
    gzip "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.gz"
    echo -e "${GREEN}✓ Backup compressed: $BACKUP_FILE${NC}"
fi

# Show backup info
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Backup completed successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Backup file: $BACKUP_FILE"
echo "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
echo "Location: $BACKUP_DIR"
echo ""

# Cleanup old backups
echo -e "${YELLOW}Cleaning up old backups (keeping last $MAX_BACKUPS)...${NC}"
BACKUP_COUNT=$(ls -1 ${BACKUP_DIR}/x-ui.db.backup.* 2>/dev/null | wc -l)

if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    BACKUPS_TO_DELETE=$((BACKUP_COUNT - MAX_BACKUPS))
    ls -1t ${BACKUP_DIR}/x-ui.db.backup.* | tail -n "$BACKUPS_TO_DELETE" | xargs rm -f
    echo -e "${GREEN}✓ Removed $BACKUPS_TO_DELETE old backup(s)${NC}"
else
    echo -e "${YELLOW}No old backups to remove${NC}"
fi

echo ""

# List current backups
echo -e "${YELLOW}Current backups:${NC}"
ls -lh ${BACKUP_DIR}/x-ui.db.backup.* 2>/dev/null || echo "No backups found"

echo ""
echo -e "${YELLOW}To restore a backup:${NC}"
echo "  1. Stop 3x-ui:    sudo x-ui stop"
echo "  2. Restore DB:    sudo zcat $BACKUP_FILE > $DB_PATH"
echo "  3. Start 3x-ui:   sudo x-ui start"
echo ""
echo "Or use the restore script: sudo ./restore-db.sh <backup-file>"
echo ""
