# 3x-ui-setup — Qwen Code Skill

## Overview

**Name:** 3x-ui-setup  
**Description:** Complete VPN server setup from scratch. Takes a fresh VPS (IP + root + password from hosting provider) through full server hardening and 3x-ui (Xray proxy panel) installation with VLESS Reality or VLESS TLS.

**Allowed Tools:** Bash, Read, Write, Edit

**Use Case:** When user mentions v2ray, xray, vless, 3x-ui, proxy server, vpn server, or wants to set up encrypted proxy access on a VPS. Designed for beginners — hand-holds through every step.

---

## Workflow Overview

```
ЧАСТЬ 1: Настройка сервера
Fresh VPS (IP + root + password) → Determine execution mode (remote or local) → 
Generate SSH key / setup access → Connect as root → Update system → 
Create non-root user + sudo → Install SSH key → TEST new user login (critical!) → 
Firewall (ufw) → Kernel hardening → Time sync + packages → Configure local ~/.ssh/config → 
✅ Server secured

ЧАСТЬ 2: Установка VPN (3x-ui)
→ Install 3x-ui panel → Enable BBR (TCP optimization) → Disable ICMP (stealth) → 
Reality: scanner → create inbound → get link → Install Hiddify client → 
Verify connection → Generate guide file (credentials + instructions) → 
Install fail2ban + lock SSH (after key verified) → ✅ VPN working
```

---

## PART 1: Server Hardening

### Step 0: Collect Information

Determine **execution mode**:

**Remote Mode** (Qwen Code on local computer) - ASK for:
1. Server IP
2. Root password
3. Desired username
4. Server nickname
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

**Recommend Reality (no domain) for beginners.**

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

### Step 1: Generate SSH Key (LOCAL)
```bash
ssh-keygen -t ed25519 -C "{username}@{nickname}" -f ~/.ssh/{nickname}_key -N ""
cat ~/.ssh/{nickname}_key.pub
```

### Step 2: First Connection as Root
```bash
ssh root@{SERVER_IP}
```
Handle forced password change if prompted.

### Step 3: System Update (as root)
```bash
apt update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y
```

### Step 4: Create Non-Root User
```bash
useradd -m -s /bin/bash {username}
echo "{username}:{GENERATE_STRONG_PASSWORD}" | chpasswd
usermod -aG sudo {username}
```

### Step 5: Install SSH Key
```bash
mkdir -p /home/{username}/.ssh
echo "{PUBLIC_KEY_CONTENT}" > /home/{username}/.ssh/authorized_keys
chmod 700 /home/{username}/.ssh
chmod 600 /home/{username}/.ssh/authorized_keys
chown -R {username}:{username} /home/{username}/.ssh
```

### Step 6: TEST New User Login — CRITICAL
```bash
ssh -i ~/.ssh/{nickname}_key {username}@{SERVER_IP}
sudo whoami  # Must output: root
```

### Step 7: Lock Down SSH — DEFERRED
**SKIP** - Done in Step 22 after SSH key is verified.

### Step 8: Firewall
```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status
```

### Step 9: fail2ban — DEFERRED
**SKIP** - Installed in Step 22.

### Step 10: Kernel Hardening
```bash
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
```

### Step 11: Time Sync + Base Packages
```bash
sudo apt install -y chrony curl wget unzip net-tools
sudo systemctl enable chrony
```

### Step 12: Configure Local SSH Config
```bash
cat >> ~/.ssh/config << 'EOF'
Host {nickname}
HostName {SERVER_IP}
User {username}
IdentityFile ~/.ssh/{nickname}_key
IdentitiesOnly yes
EOF
```

### Step 13: Final Verification
```bash
ssh {nickname}
sudo ufw status
sudo sysctl net.ipv4.conf.all.rp_filter
```

---

## PART 2: VPN Installation (3x-ui)

### Step 14: Install 3x-ui
```bash
ssh {nickname} "curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3x-ui-install.sh && echo 'n' | sudo bash /tmp/3x-ui-install.sh"
```

### Step 14b: Enable BBR
```bash
ssh {nickname} 'current=$(sysctl -n net.ipv4.tcp_congestion_control); echo "Current: $current"; if [ "$current" != "bbr" ]; then echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf && sudo sysctl -p && echo "BBR enabled"; else echo "BBR already active"; fi'
```

### Step 15: Disable ICMP (Stealth)
```bash
ssh {nickname} "sudo sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules && sudo sed -i 's/-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules && sudo ufw reload"
```

### Step 16: Branch — Reality or TLS
- **Path A:** VLESS Reality (NO domain) — RECOMMENDED → Step 17A
- **Path B:** VLESS TLS (domain required) → `references/vless-tls.md`

### Step 17A: Reality Scanner (Remote Mode)
```bash
ssh {nickname} 'ARCH=$(dpkg --print-architecture); case "$ARCH" in amd64) SA="64";; arm64|aarch64) SA="arm64-v8a";; *) SA="$ARCH";; esac && curl -sL "https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-${SA}" -o /tmp/scanner && chmod +x /tmp/scanner && file /tmp/scanner | grep -q ELF || { echo "ERROR: scanner binary not valid for this architecture"; exit 1; }; MY_IP=$(curl -4 -s ifconfig.me); SUBNET=$(echo $MY_IP | sed "s/\.[0-9]*$/.0\/24/"); echo "Scanning subnet: $SUBNET"; timeout 120 /tmp/scanner --addr "$SUBNET" 2>&1 | head -80'
```

### Step 18A: Create VLESS Reality Inbound via API
```bash
# Get session cookie
ssh {nickname} 'PANEL_PORT={panel_port}; curl -sk -c /tmp/3x-cookie -b /tmp/3x-cookie -X POST "https://127.0.0.1:${PANEL_PORT}/${web_base_path}/login" -H "Content-Type: application/x-www-form-urlencoded" -d "username={panel_username}&password={panel_password}"'

# Generate keys
ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* x25519"
ssh {nickname} "sudo /usr/local/x-ui/bin/xray-linux-* uuid"
ssh {nickname} "openssl rand -hex 8"

# Create inbound (full JSON payload)
```

### Step 19: Get Connection Link
```bash
ssh {nickname} 'PANEL_PORT={panel_port}; curl -sk -b /tmp/3x-cookie "https://127.0.0.1:${PANEL_PORT}/${web_base_path}/panel/api/inbounds/list" | python3 -c "
import json,sys
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
            link = f\"vless://{uuid}@$(curl -4 -s ifconfig.me):{port}?type=tcp&security=reality&pbk={pbk}&fp={fp}&sni={sni}&sid={sid}&spx=%2F&flow={flow}#vless-reality\"
            print(link)
            break
"'
```

### Step 20: Install Hiddify Client
Guide user to install Hiddify on their device and add the VLESS link.

### Step 21: Verify Connection
```bash
ssh {nickname} "sudo x-ui status && ss -tlnp | grep -E '443|{panel_port}'"
```

### Step 22: Generate Guide File & Finalize

**Remote Mode:**
1. Generate guide file locally: `~/vpn-{nickname}-guide.md`
2. Verify SSH key access works
3. Install fail2ban + lock SSH

**Local Mode:**
1. Generate guide file on server: `/home/{username}/vpn-guide.md`
2. User downloads via SCP
3. User creates SSH key on laptop
4. User sends public key via SCP
5. Install key + verify
6. Install fail2ban + lock SSH
7. User configures SSH config
8. Delete guide file from server

---

## Guide File Template

Contains:
1. Server connection details (IP, user, SSH key, sudo password)
2. 3x-ui panel credentials (URL, login, password)
3. VPN connection details (VLESS link, SNI, protocol)
4. SSH key setup instructions (macOS/Linux/Windows)
5. Common commands
6. Security status
7. Troubleshooting
8. Instructions for Qwen Code automation

---

## Critical Rules

### Part 1 (Server)
1. **NEVER skip Step 6** (test login)
2. **NEVER disable root before confirming new user works**
3. **NEVER store passwords in files**
4. **If connection drops** after password change — reconnect
5. **If Step 6 fails** — fix before proceeding
6. **Generate SSH key BEFORE first connection**
7. **All operations after Step 6 use sudo**
8. **Steps 7 and 9 are DEFERRED** to Step 22

### Part 2 (VPN)
9. **NEVER expose panel to internet** — SSH tunnel only
10. **NEVER skip firewall configuration**
11. **ALWAYS save panel credentials**
12. **ALWAYS verify connection works**
13. **Ask before every destructive action**
14. **ALWAYS generate guide file**
15. **Lock SSH + fail2ban LAST** (Step 22)
16. **NEVER leave password auth enabled** after setup

---

## x-ui CLI Reference
```bash
x-ui start          # start panel
x-ui stop           # stop panel
x-ui restart        # restart panel
x-ui status         # check status
x-ui setting -reset # reset username/password
x-ui log            # view logs
x-ui cert           # manage SSL certificates
x-ui update         # update to latest version
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection drops after password change | Normal — reconnect |
| Permission denied (publickey) | Check key path/permissions (700/600) |
| Host key verification failed | `ssh-keygen -R {SERVER_IP}` |
| x-ui install fails | `sudo apt install -y curl tar` |
| Panel not accessible | Use SSH tunnel |
| Reality not connecting | Wrong SNI — re-run scanner |
| Hiddify shows error | Update Hiddify, re-add link |
| Forgot panel password | `sudo x-ui setting -reset` |
