# 3x-ui-setup — Qwen Code Skill (v2.0)

## Overview

**Name:** 3x-ui-setup  
**Version:** 2.0.0  
**Description:** Complete VPN server setup from scratch. Takes a fresh VPS through full server hardening and 3x-ui installation with VLESS Reality or VLESS TLS.

**Allowed Tools:** Bash, Read, Write, Edit

**Use Case:** When user mentions v2ray, xray, vless, 3x-ui, proxy server, vpn server, or wants to set up encrypted proxy access on a VPS.

---

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    3x-ui-setup Skill Flow                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  STEP 0: Collect Info & Validate                                │
│  ├─ Determine mode (Remote/Local)                               │
│  ├─ Collect credentials                                         │
│  └─ Validate inputs ✓ NEW                                       │
│                                                                  │
│  PART 1: Server Hardening (Steps 1-13)                          │
│  ├─ SSH key generation                                          │
│  ├─ Root connection                                             │
│  ├─ System update                                               │
│  ├─ User creation + validation ✓ NEW                            │
│  ├─ SSH key installation                                        │
│  ├─ TEST login (CRITICAL)                                       │
│  ├─ Firewall (UFW)                                              │
│  ├─ Kernel hardening                                            │
│  ├─ Time sync + packages (incl. SQLite3) ✓ NEW                  │
│  └─ SSH config setup                                            │
│                                                                  │
│  PART 2: VPN Installation (Steps 14-22)                         │
│  ├─ 3x-ui panel install                                         │
│  ├─ BBR optimization                                            │
│  ├─ ICMP stealth                                                │
│  ├─ Protocol selection (Reality/TLS)                            │
│  ├─ Reality scanner + inbound setup ✓ IMPROVED                  │
│  ├─ Connection link generation                                  │
│  ├─ Hiddify client setup                                        │
│  ├─ Connection verification                                     │
│  ├─ Guide file generation ✓ NEW                                 │
│  └─ fail2ban + SSH lock                                         │
│                                                                  │
│  OUTPUT: Secured server + Working VPN + Guide file              │
└─────────────────────────────────────────────────────────────────┘
```

---

## PART 0: Information Collection & Validation

### Step 0.1: Determine Execution Mode

**Remote Mode** (Qwen Code on local computer) - ASK for:
1. Server IP address
2. Root password (temporary, for initial connection)
3. Desired username (3-16 chars, lowercase letters + numbers only)
4. Server nickname (for SSH config)
5. Has domain? (recommend "no" for Reality)
6. Domain name (if yes to #5)

**Local Mode** (Qwen Code on the server itself) - ASK for:
1. Desired username
2. Server nickname
3. Has domain?
4. Domain name (if yes to #3)

In Local mode, get server IP automatically:
```bash
curl -4 -s ifconfig.me
```

### Step 0.2: Input Validation ✓ NEW

**Validate IP Address:**
```bash
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Usage
if ! validate_ip "$SERVER_IP"; then
    echo "ERROR: Invalid IP address format"
    exit 1
fi
```

**Validate Username:**
```bash
validate_username() {
    local username=$1
    if [[ $username =~ ^[a-z][a-z0-9]{2,15}$ ]]; then
        return 0
    fi
    return 1
}

# Usage
if ! validate_username "$USERNAME"; then
    echo "ERROR: Username must be 3-16 chars, start with letter, lowercase only"
    exit 1
fi
```

**Validate Domain (if provided):**
```bash
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}
```

**Check OS Compatibility:**
```bash
check_os_compatibility() {
    if [ ! -f /etc/debian_version ]; then
        echo "ERROR: Only Debian/Ubuntu systems are supported"
        exit 1
    fi
    
    local version=$(cat /etc/debian_version)
    local major_version=$(echo $version | cut -d'.' -f1)
    
    if [ "$major_version" -lt 10 ]; then
        echo "WARNING: Debian version < 10 may have compatibility issues"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            exit 0
        fi
    fi
}
```

---

## PART 1: Server Hardening

### Execution Modes Comparison

| Step | Remote Mode | Local Mode |
|------|-------------|------------|
| Step 1 | Generate SSH key on LOCAL | **SKIP** |
| Step 2 | `ssh root@{SERVER_IP}` | Already on server |
| Steps 3-4 | Run on server via root SSH | Run directly |
| Step 5 | Install local public key on server | **SKIP** |
| Step 6 | SSH test from LOCAL | Switch user: `su - {username}` |
| Step 7 | **SKIP** (deferred) | **SKIP** (deferred) |
| Steps 8-11 | `sudo` on server via SSH | `sudo` directly |
| Step 12 | Write `~/.ssh/config` on LOCAL | **SKIP** |
| Step 13 | Verify via `ssh {nickname}` | Run audit directly |
| Part 2 | `ssh {nickname} "sudo ..."` | `sudo ...` directly |
| Step 17A | Scanner via `ssh {nickname} '...'` | Scanner runs directly |
| Step 22 | Generate guide + fail2ban + lock SSH | Generate guide → SCP → SSH key → fail2ban |

---

### Step 1: Generate SSH Key (LOCAL) ✓ IMPROVED

```bash
# Create SSH key with backup reminder
ssh-keygen -t ed25519 -C "{username}@{nickname}" -f ~/.ssh/{nickname}_key -N ""

# IMPORTANT: Backup reminder
echo ""
echo "⚠️  IMPORTANT: Backup your SSH key!"
echo "Key location: ~/.ssh/{nickname}_key"
echo ""
echo "Recommended backup options:"
echo "  1. Copy to USB drive"
echo "  2. Save to password manager"
echo "  3. Store in secure cloud storage"
echo ""
echo "If you lose this key, you may lose access to your server!"
echo ""

# Display public key
cat ~/.ssh/{nickname}_key.pub
```

---

### Step 2: First Connection as Root

```bash
ssh root@{SERVER_IP}
```

Handle forced password change if prompted.

---

### Step 3: System Update (as root)

```bash
echo "[3/22] ⏳ Updating system packages..."
apt update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y
echo "[3/22] ✓ System updated"
```

---

### Step 4: Create Non-Root User ✓ IMPROVED

```bash
# Generate strong password
generate_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24
}

USER_PASSWORD=$(generate_password)

# Create user
useradd -m -s /bin/bash {username}
echo "{username}:${USER_PASSWORD}" | chpasswd
usermod -aG sudo {username}

echo "[4/22] ✓ User '{username}' created"
echo "! Save this password temporarily: ${USER_PASSWORD}"
```

---

### Step 5: Install SSH Key

```bash
mkdir -p /home/{username}/.ssh
cat ~/.ssh/{nickname}_key.pub > /home/{username}/.ssh/authorized_keys
chmod 700 /home/{username}/.ssh
chmod 600 /home/{username}/.ssh/authorized_keys
chown -R {username}:{username} /home/{username}/.ssh

echo "[5/22] ✓ SSH key installed"
```

---

### Step 6: TEST New User Login — CRITICAL

```bash
echo "[6/22] ⏳ Testing new user login..."

# Test connection
if ssh -i ~/.ssh/{nickname}_key -o StrictHostKeyChecking=no -o ConnectTimeout=10 {username}@{SERVER_IP} "sudo whoami"; then
    echo "[6/22] ✓ SSH login test successful"
else
    echo "[6/22] ✗ SSH login test FAILED"
    echo "Troubleshooting:"
    echo "  1. Check key permissions: chmod 600 ~/.ssh/{nickname}_key"
    echo "  2. Verify key was copied correctly"
    echo "  3. Try reconnecting as root and re-check authorized_keys"
    exit 1
fi
```

---

### Step 7: Lock Down SSH — DEFERRED

**SKIP** - Done in Step 22 after SSH key is verified.

---

### Step 8: Firewall ✓ IMPROVED

```bash
echo "[8/22] ⏳ Configuring firewall..."

sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "[8/22] ✓ Firewall configured"
sudo ufw status verbose
```

---

### Step 9: fail2ban — DEFERRED

**SKIP** - Installed in Step 22.

---

### Step 10: Kernel Hardening

```bash
echo "[10/22] ⏳ Applying kernel hardening..."

sudo tee /etc/sysctl.d/99-security.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
EOF

sudo sysctl -p /etc/sysctl.d/99-security.conf

echo "[10/22] ✓ Kernel hardening applied"
```

---

### Step 11: Time Sync + Base Packages ✓ IMPROVED (SQLite3 added)

```bash
echo "[11/22] ⏳ Installing base packages..."

# Install packages including SQLite3 for 3x-ui database
sudo apt install -y chrony curl wget unzip net-tools sqlite3

sudo systemctl enable chrony
sudo systemctl start chrony

# Verify SQLite3 installation
if command -v sqlite3 &> /dev/null; then
    echo "[11/22] ✓ Base packages installed (including SQLite3)"
    sqlite3 --version
else
    echo "[11/22] ! SQLite3 installation failed - will retry later"
fi
```

---

### Step 12: Configure Local SSH Config

```bash
echo "[12/22] ⏳ Configuring SSH shortcut..."

# Backup existing config
if [ -f ~/.ssh/config ]; then
    cp ~/.ssh/config ~/.ssh/config.backup
fi

# Add new host entry
cat >> ~/.ssh/config << EOF

# 3x-ui server - {nickname}
Host {nickname}
    HostName {SERVER_IP}
    User {username}
    IdentityFile ~/.ssh/{nickname}_key
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF

chmod 600 ~/.ssh/config

echo "[12/22] ✓ SSH config updated"
```

---

### Step 13: Final Verification

```bash
echo "[13/22] ⏳ Running final verification..."

ssh {nickname} "sudo ufw status"
ssh {nickname} "sudo sysctl net.ipv4.conf.all.rp_filter"

echo "[13/22] ✓ Part 1 complete - Server secured!"
echo ""
echo "═══════════════════════════════════════════"
echo "  PART 1 COMPLETE: Server is now hardened"
echo "═══════════════════════════════════════════"
```

---

## PART 2: VPN Installation (3x-ui)

### Step 14: Install 3x-ui ✓ IMPROVED

```bash
echo "[14/22] ⏳ Installing 3x-ui panel..."

ssh {nickname} "
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3x-ui-install.sh
    echo 'n' | sudo bash /tmp/3x-ui-install.sh
"

echo "[14/22] ✓ 3x-ui panel installed"
```

---

### Step 14b: Enable BBR

```bash
echo "[14b/22] ⏳ Enabling BBR optimization..."

ssh {nickname} '
current=$(sysctl -n net.ipv4.tcp_congestion_control)
echo "Current congestion control: $current"
if [ "$current" != "bbr" ]; then
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
    echo "✓ BBR enabled"
else
    echo "✓ BBR already active"
fi
'

echo "[14b/22] ✓ BBR configuration complete"
```

---

### Step 15: Disable ICMP (Stealth)

```bash
echo "[15/22] ⏳ Disabling ICMP (stealth mode)..."

ssh {nickname} "
    sudo sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
    sudo sed -i 's/-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
    sudo ufw reload
"

echo "[15/22] ✓ ICMP disabled (server won't respond to pings)"
```

---

### Step 16: Branch — Reality or TLS

- **Path A:** VLESS Reality (NO domain) — RECOMMENDED → Step 17A
- **Path B:** VLESS TLS (domain required) → `references/vless-tls.md`

---

### Step 17A: Reality Scanner ✓ IMPROVED

```bash
echo "[17A/22] ⏳ Running Reality scanner..."

ssh {nickname} '
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) SA="64" ;;
    arm64|aarch64) SA="arm64-v8a" ;;
    *) echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Downloading scanner for $ARCH..."
curl -sL "https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-${SA}" -o /tmp/scanner
chmod +x /tmp/scanner

# Verify binary
if ! file /tmp/scanner | grep -q ELF; then
    echo "ERROR: Scanner binary not valid for this architecture"
    exit 1
fi

MY_IP=$(curl -4 -s ifconfig.me)
SUBNET=$(echo $MY_IP | sed "s/\.[0-9]*$/.0\/24/")

echo "Scanning subnet: $SUBNET"
echo "This may take up to 2 minutes..."
timeout 120 /tmp/scanner --addr "$SUBNET" 2>&1 | head -80
'

echo "[17A/22] ✓ Scanner complete - review results above"
```

---

### Step 18A: Create VLESS Reality Inbound ✓ COMPLETE

```bash
# Get panel info first
echo "[18A/22] ⏳ Creating VLESS Reality inbound..."

# Get session cookie
ssh {nickname} '
PANEL_PORT=$(sudo cat /etc/x-ui/x-ui.sh 2>/dev/null | grep -oP "PORT=\K\d+" || echo "54321")
WEB_BASE_PATH=$(sudo cat /etc/x-ui/x-ui.sh 2>/dev/null | grep -oP "WEB_BASE_PATH=\K[^\"]+" || echo "")
curl -sk -c /tmp/3x-cookie -b /tmp/3x-cookie -X POST "https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username={panel_username}&password={panel_password}"
'

# Generate keys
PRIVATE_KEY=$(ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* x25519 2>/dev/null | grep 'Private key' | awk '{print \$3}'")
PUBLIC_KEY=$(ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* x25519 2>/dev/null | grep 'Public key' | awk '{print \$3}'")
CLIENT_UUID=$(ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* uuid 2>/dev/null | head -1")
SHORT_ID=$(ssh {nickname} "openssl rand -hex 8")

echo "Generated keys:"
echo "  Private Key: ${PRIVATE_KEY:0:20}..."
echo "  Public Key: ${PUBLIC_KEY:0:20}..."
echo "  Client UUID: ${CLIENT_UUID:0:20}..."
echo "  Short ID: ${SHORT_ID}"

# Create inbound via API
ssh {nickname} "
PANEL_PORT={panel_port}
WEB_BASE_PATH={web_base_path}

curl -sk -c /tmp/3x-cookie -b /tmp/3x-cookie -X POST \"https://127.0.0.1:\${PANEL_PORT}/\${WEB_BASE_PATH}/panel/api/inbounds/add\" \
    -H 'Content-Type: application/json' \
    -d '{
        \"up\": 0,
        \"down\": 0,
        \"total\": 0,
        \"remark\": \"vless-reality\",
        \"enable\": true,
        \"expiryTime\": 0,
        \"listen\": \"\",
        \"port\": 443,
        \"protocol\": \"vless\",
        \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"${CLIENT_UUID}\\\",\\\"flow\\\":\\\"xtls-rprx-vision\\\",\\\"email\\\":\\\"user1\\\",\\\"limitIp\\\":0,\\\"totalGB\\\":0,\\\"expiryTime\\\":0,\\\"enable\\\":true}],\\\"decryption\\\":\\\"none\\\",\\\"fallbacks\\\":[]}\",
        \"streamSettings\": \"{\\\"network\\\":\\\"tcp\\\",\\\"security\\\":\\\"reality\\\",\\\"externalProxy\\\":[],\\\"realitySettings\\\":{\\\"show\\\":false,\\\"dest\\\":\\\"google.com:443\\\",\\\"xver\\\":0,\\\"serverNames\\\":[\\\"google.com\\\"],\\\"privateKey\\\":\\\"${PRIVATE_KEY}\\\",\\\"minClientVer\\\":\\\"\\\",\\\"maxClientVer\\\":\\\"\\\",\\\"maxTimeDiff\\\":0,\\\"shortIds\\\":[\\\"${SHORT_ID}\\\"],\\\"settings\\\":{\\\"publicKey\\\":\\\"${PUBLIC_KEY}\\\",\\\"fingerprint\\\":\\\"chrome\\\"}}}\",
        \"sniffing\": \"{\\\"enabled\\\":true,\\\"destOverride\\\":[\\\"http\\\",\\\"tls\\\",\\\"quic\\\",\\\"fakedns\\\"],\\\"metadataOnly\\\":false,\\\"routeOnly\\\":false}\",
        \"allocate\": \"{\\\"strategy\\\":\\\"always\\\",\\\"refresh\\\":5,\\\"concurrency\\\":3}\"
    }'
"

echo "[18A/22] ✓ VLESS Reality inbound created"
```

---

### Step 19: Get Connection Link ✓ IMPROVED

```bash
echo "[19/22] ⏳ Generating connection link..."

VLESS_LINK=$(ssh {nickname} '
PANEL_PORT={panel_port}
WEB_BASE_PATH={web_base_path}

curl -sk -b /tmp/3x-cookie "https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/panel/api/inbounds/list" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for inb in data.get(\"obj\", []):
    if inb.get(\"protocol\") == \"vless\":
        settings = json.loads(inb[\"settings\"])
        stream = json.loads(inb[\"streamSettings\"])
        client = settings[\"clients\"][0]
        uuid = client[\"id\"]
        port = inb[\"port\"]
        security = stream.get(\"security\", \"none\")
        if security == \"reality\":
            rs = stream[\"realitySettings\"]
            sni = rs[\"serverNames\"][0]
            pbk = rs[\"settings\"][\"publicKey\"]
            sid = rs[\"shortIds\"][0]
            fp = rs[\"settings\"].get(\"fingerprint\", \"chrome\")
            flow = client.get(\"flow\", \"\")
            my_ip = \"$(curl -4 -s ifconfig.me)\"
            link = f\"vless://{uuid}@{my_ip}:{port}?type=tcp&security=reality&pbk={pbk}&fp={fp}&sni={sni}&sid={sid}&spx=%2F&flow={flow}#vless-reality\"
            print(link)
            break
"
')

echo "[19/22] ✓ Connection link generated"
echo ""
echo "VLESS Link:"
echo "${VLESS_LINK}"
echo ""
```

---

### Step 20: Install Hiddify Client

Guide user to install Hiddify on their device:

1. **Android/iOS:** Download from [Hiddify GitHub](https://github.com/hiddify/hiddify-app/releases)
2. **Desktop:** Download from [Hiddify GitHub](https://github.com/hiddify/hiddify-app/releases)
3. Import the VLESS link from Step 19
4. Connect and verify

---

### Step 21: Verify Connection

```bash
echo "[21/22] ⏳ Verifying connection..."

ssh {nickname} "
    sudo x-ui status
    ss -tlnp | grep -E '443|{panel_port}'
"

echo "[21/22] ✓ Verification complete"
```

---

### Step 22: Generate Guide File & Finalize ✓ COMPLETE

**Generate Guide File:**

```bash
echo "[22/22] ⏳ Generating guide file..."

# Get panel info
PANEL_PORT=$(ssh {nickname} "sudo cat /etc/x-ui/x-ui.sh 2>/dev/null | grep -oP 'PORT=\K\d+' || echo '54321'")
PANEL_USER="{panel_username}"
PANEL_PASS="{panel_password}"

# Create guide file
cat > ~/vpn-{nickname}-guide.md << EOF
# VPN Connection Guide - ${nickname}

Generated: $(date)

---

## 🔐 Server Connection Details

| Setting | Value |
|---------|-------|
| IP Address | ${SERVER_IP} |
| Username | ${username} |
| SSH Key | ~/.ssh/${nickname}_key |
| SSH Command | \`ssh ${nickname}\` |

### SSH Key Backup ⚠️

**IMPORTANT:** Backup your SSH key immediately!
- Location: \`~/.ssh/${nickname}_key\`
- Backup to: USB drive, password manager, or secure cloud

If you lose this key, you may lose access to your server!

---

## 🖥️ 3x-ui Panel Access

| Setting | Value |
|---------|-------|
| URL | https://${SERVER_IP}:${PANEL_PORT}/${WEB_BASE_PATH} |
| Username | ${PANEL_USER} |
| Password | ${PANEL_PASS} |

### Access via SSH Tunnel (Recommended)

\`\`\`bash
ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} ${nickname}
\`\`\`

Then open: \`https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}\`

---

## 🔗 VPN Connection

**Protocol:** VLESS Reality

**Connection Link:**
\`\`\`
${VLESS_LINK}
\`\`\`

### Quick Import
1. Install Hiddify: https://github.com/hiddify/hiddify-app/releases
2. Open Hiddify
3. Tap "+" or "Add Profile"
4. Paste the link above
5. Connect!

---

## 🛡️ Security Status

| Feature | Status |
|---------|--------|
| SSH Key Auth | ✓ Enabled |
| Root Login | ✗ Disabled |
| Password Auth | ✗ Disabled |
| Firewall (UFW) | ✓ Enabled |
| fail2ban | ✓ Enabled |
| Kernel Hardening | ✓ Applied |
| ICMP (Ping) | ✗ Blocked (Stealth) |
| BBR Optimization | ✓ Enabled |

---

## 📋 Common Commands

\`\`\`bash
# Connect to server
ssh ${nickname}

# Check panel status
sudo x-ui status

# View panel logs
sudo x-ui log

# Restart panel
sudo x-ui restart

# Reset panel password
sudo x-ui setting -reset

# Check firewall status
sudo ufw status

# Check fail2ban status
sudo fail2ban-client status
\`\`\`

---

## 🔧 Troubleshooting

### Connection Issues
1. Verify Hiddify is updated to latest version
2. Re-import the VLESS link
3. Try different SNI in Hiddify settings

### Panel Access Issues
1. Use SSH tunnel (see above)
2. Check panel status: \`sudo x-ui status\`
3. Reset password: \`sudo x-ui setting -reset\`

### Server Access Issues
1. Check SSH key permissions: \`chmod 600 ~/.ssh/${nickname}_key\`
2. Verify server is running: \`ping ${SERVER_IP}\` (will fail if ICMP blocked - normal!)
3. Try SSH: \`ssh -v ${nickname}\`

---

## 📞 Support

- Skill Repository: https://github.com/GilGameshx1/3x-ui-skill
- 3x-ui Documentation: https://github.com/MHSanaei/3x-ui/wiki
- Hiddify Support: https://github.com/hiddify/hiddify-app

---

## ⚠️ Security Reminders

1. **NEVER** share your SSH private key
2. **NEVER** expose panel to public internet
3. **ALWAYS** use SSH tunnel for panel access
4. **BACKUP** your SSH key to multiple locations
5. **UPDATE** regularly: \`sudo x-ui update\`

---

*Generated by 3x-ui-setup Skill for Qwen Code*
EOF

echo "[22/22] ✓ Guide file created: ~/vpn-{nickname}-guide.md"
```

**Install fail2ban and Lock SSH:**

```bash
# Install fail2ban
ssh {nickname} "
    sudo apt install -y fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
"

# Lock down SSH (disable root and password auth)
ssh {nickname} "
    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sudo systemctl restart sshd
"

echo ""
echo "═══════════════════════════════════════════"
echo "  PART 2 COMPLETE: VPN is now running!"
echo "═══════════════════════════════════════════"
echo ""
echo "✓ Guide file: ~/vpn-{nickname}-guide.md"
echo "✓ fail2ban installed"
echo "✓ SSH locked down (root/password disabled)"
echo ""
echo "🎉 All done! Your VPN is ready to use!"
```

---

## Critical Rules

### Part 1 (Server)
1. **NEVER skip Step 6** (test login)
2. **NEVER disable root before confirming new user works**
3. **NEVER store passwords in files** (except temporary guide)
4. **If connection drops** after password change — reconnect
5. **If Step 6 fails** — fix before proceeding
6. **Generate SSH key BEFORE first connection**
7. **All operations after Step 6 use sudo**
8. **Steps 7 and 9 are DEFERRED** to Step 22
9. **ALWAYS remind user to backup SSH key**

### Part 2 (VPN)
10. **NEVER expose panel to internet** — SSH tunnel only
11. **NEVER skip firewall configuration**
12. **ALWAYS save panel credentials**
13. **ALWAYS verify connection works**
14. **Ask before every destructive action**
15. **ALWAYS generate guide file**
16. **Lock SSH + fail2ban LAST** (Step 22)
17. **NEVER leave password auth enabled** after setup
18. **SQLite3 must be installed** for 3x-ui database

---

## x-ui CLI Reference

```bash
x-ui start          # Start panel
x-ui stop           # Stop panel
x-ui restart        # Restart panel
x-ui status         # Check status
x-ui setting -reset # Reset username/password
x-ui log            # View logs
x-ui cert           # Manage SSL certificates
x-ui update         # Update to latest version
```

---

## SQLite3 Database Management ✓ NEW

The 3x-ui panel uses SQLite3 for its database:

**Database Location:** `/etc/x-ui/x-ui.db`

**Backup Database:**
```bash
ssh {nickname} "sudo cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.backup.$(date +%Y%m%d)"
```

**Restore Database:**
```bash
ssh {nickname} "sudo cp /etc/x-ui/x-ui.db.backup.YYYYMMDD /etc/x-ui/x-ui.db && sudo x-ui restart"
```

**Query Database:**
```bash
ssh {nickname} "sudo sqlite3 /etc/x-ui/x-ui.db '.tables'"
ssh {nickname} "sudo sqlite3 /etc/x-ui/x-ui.db 'SELECT * FROM inbounds;'"
```

**Export Database:**
```bash
scp {nickname}:/etc/x-ui/x-ui.db ~/backup-x-ui-$(date +%Y%m%d).db
```

---

## Rollback Script ✓ NEW

Create rollback script for emergency recovery:

```bash
cat > ~/3x-ui-rollback.sh << 'ROLLBACK'
#!/bin/bash
# 3x-ui-setup Rollback Script

echo "=== 3x-ui-setup Rollback ==="
echo ""
echo "This script will:"
echo "  1. Remove 3x-ui panel"
echo "  2. Remove non-root user"
echo "  3. Restore SSH to default"
echo "  4. Disable firewall"
echo ""
read -p "Continue? (y/N): " confirm

if [ "$confirm" != "y" ]; then
    echo "Cancelled"
    exit 0
fi

# Remove 3x-ui
echo "Removing 3x-ui..."
sudo /usr/local/x-ui/x-ui.sh uninstall

# Remove user (replace with actual username)
echo "Enter username to remove:"
read username
sudo userdel -r $username 2>/dev/null

# Restore SSH
echo "Restoring SSH defaults..."
sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd

# Disable firewall
echo "Disabling firewall..."
sudo ufw --force disable

echo ""
echo "Rollback complete!"
echo "Server will need manual cleanup for:"
echo "  - Kernel hardening (/etc/sysctl.d/99-security.conf)"
echo "  - fail2ban configuration"
echo "  - SSH config entries"
ROLLBACK

chmod +x ~/3x-ui-rollback.sh
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection drops after password change | Normal — reconnect with new credentials |
| Permission denied (publickey) | Check key path/permissions (700/600) |
| Host key verification failed | `ssh-keygen -R {SERVER_IP}` |
| x-ui install fails | `sudo apt install -y curl tar` |
| Panel not accessible | Use SSH tunnel |
| Reality not connecting | Wrong SNI — re-run scanner |
| Hiddify shows error | Update Hiddify, re-add link |
| Forgot panel password | `sudo x-ui setting -reset` |
| SQLite3 database error | `sudo apt install --reinstall sqlite3` |
| Database corrupted | Restore from backup |

---

## Version History

- **v2.0.0** - Complete refactor with SQLite3 support, input validation, progress indicators, rollback script
- **v1.0.0** - Initial adaptation from Claude Code skill
