# 3x-ui-setup — Qwen Code Skill

A **Qwen Code skill** that fully automates VPN server deployment on a fresh VPS. It handles everything from OS hardening to a working VLESS proxy with client setup instructions. Designed for beginners who want a secure, censorship-resistant connection without learning sysadmin or proxy protocols.

---

## 🚀 Quick Start

### Installation

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/GilGameshx1/3x-ui-skill/main/install.sh | bash
```

**Or manual install:**
```bash
git clone https://github.com/GilGameshx1/3x-ui-skill.git
cp -r 3x-ui-skill/skill ~/.qwen/skills/3x-ui-setup
rm -rf 3x-ui-skill
```

### Usage

After installation, open **Qwen Code** and use natural language commands:
- *"Set up a VPN on my VPS"*
- *"I have a new server, help me configure VLESS"*
- *"Harden my server and install 3x-ui"*

The skill activates automatically when Qwen detects a relevant request.

---

## 📋 Requirements

| Requirement | Details |
|-------------|---------|
| **Qwen Code (CLI)** | Required to invoke the skill |
| **Fresh VPS** | Ubuntu/Debian with root access |
| **SSH access** | From your local machine to the server |
| **Domain name** | Optional — only needed for VLESS TLS (not required for Reality) |

**Underlying Projects:**
- **[3x-ui](https://github.com/mhsanaei/3x-ui)** — Xray panel with multi-protocol support
- **[Xray-core](https://github.com/XTLS/Xray-core)** — Proxy engine for VLESS, Reality
- **[Hiddify](https://github.com/hiddify/hiddify-app)** — Cross-platform proxy client

---

## 📁 File Structure

```
3x-ui-skill/
├── skill/                          # Main skill directory
│   ├── SKILL.md                    # Core skill definition & automation logic
│   └── references/
│       ├── vless-tls.md            # VLESS TLS setup path (domain required)
│       └── fallback-nginx.md       # Nginx fallback page configuration
├── install.sh                      # One-line installer script
├── README.md                       # English documentation
├── README.ru.md                    # Russian documentation
├── LICENSE                         # MIT license
└── .gitignore
```

---

## 🔧 Workflow Overview

```
Fresh VPS (IP + root + password)
  │
  ├── Part 1: Server Hardening
  │   ├── SSH key generation
  │   ├── System update
  │   ├── Non-root user + sudo
  │   ├── SSH lockdown (no root, no passwords)
  │   ├── UFW firewall
  │   ├── fail2ban
  │   ├── Kernel hardening
  │   └── SSH config shortcut
  │
  ├── Part 2: VPN Installation
  │   ├── 3x-ui panel install
  │   ├── BBR (TCP optimization)
  │   ├── ICMP disabled (stealth mode)
  │   ├── Protocol setup (Reality or TLS)
  │   ├── Connection link generation
  │   └── Hiddify client setup
  │
  └── Done: Secured server + Working VPN
```

---

## 🌐 Supported Protocols

| Feature | VLESS Reality | VLESS TLS |
|---------|---------------|-----------|
| Domain required | No | Yes |
| SSL certificate | Not needed | Auto (acme.sh) |
| Difficulty | Easy | Medium |
| Recommended for | Beginners | Advanced users |
| Stealth | High | Medium |

---

## 📖 Detailed Documentation

### Part 1: Server Hardening

The skill will guide you through:
1. **SSH Key Setup** — Secure key-based authentication
2. **System Update** — Latest security patches
3. **User Creation** — Non-root sudo user
4. **Firewall Configuration** — UFW with minimal open ports
5. **Kernel Hardening** — Sysctl security tweaks
6. **Fail2Ban** — Intrusion prevention
7. **SSH Config** — Easy connection shortcuts

### Part 2: VPN Installation

1. **3x-ui Panel** — Modern web interface for Xray
2. **BBR Optimization** — TCP congestion control for better speeds
3. **ICMP Stealth** — Server doesn't respond to pings
4. **Protocol Selection**:
   - **Reality** (recommended) — No domain needed, highest stealth
   - **TLS** — Requires domain, traditional SSL setup
5. **Client Setup** — Hiddify app configuration
6. **Connection Guide** — Generated markdown file with all credentials

---

## 🔒 Security Features

- ✅ SSH key-only authentication (no passwords)
- ✅ Root login disabled
- ✅ Firewall with minimal open ports
- ✅ Fail2Ban intrusion prevention
- ✅ Kernel security hardening
- ✅ Panel accessible only via SSH tunnel
- ✅ VLESS Reality for maximum stealth

---

## 🛠️ Troubleshooting

### Common Issues

| Problem | Solution |
|---------|----------|
| Connection drops after password change | Normal — reconnect with new credentials |
| Permission denied (publickey) | Check key path/permissions (700/600) |
| Host key verification failed | `ssh-keygen -R {SERVER_IP}` |
| x-ui install fails | `sudo apt install -y curl tar` |
| Panel not accessible | Use SSH tunnel: `ssh -L 8080:127.0.0.1:{port} user@server` |
| Reality not connecting | Wrong SNI — re-run scanner |
| Hiddify shows error | Update Hiddify, re-add link |
| Forgot panel password | `sudo x-ui setting -reset` |

### Getting Help

1. Check the generated guide file (`~/vpn-{nickname}-guide.md`)
2. Ask Qwen Code: *"Help me troubleshoot my VPN connection"*
3. Review 3x-ui logs: `sudo x-ui log`

---

## 📝 License

MIT License — feel free to modify and distribute.

---

## 🙏 Credits

This skill is adapted from the original [3x-ui-skill by AndyShaman](https://github.com/AndyShaman/3x-ui-skill) for Claude Code, modified for Qwen Code.

---

## 📚 Additional Resources

- [3x-ui GitHub](https://github.com/mhsanaei/3x-ui)
- [Xray-core Documentation](https://github.com/XTLS/Xray-core)
- [Hiddify Client](https://github.com/hiddify/hiddify-app)
- [RealiTLScanner](https://github.com/XTLS/RealiTLScanner)
