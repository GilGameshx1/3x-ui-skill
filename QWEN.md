# Qwen Code Skill Activation Configuration

## Skill Metadata

**Name:** 3x-ui-setup  
**Version:** 2.0.0  
**Author:** GilGameshx1 (adapted from AndyShaman)  
**Description:** Complete VPN server setup from scratch with server hardening and 3x-ui panel installation

---

## Activation Triggers

The skill should activate when the user mentions any of the following:

### Primary Triggers
- "vpn", "vps", "vless", "xray", "3x-ui", "proxy server"
- "set up server", "harden server", "install vpn"
- "configure proxy", "setup v2ray", "deploy vpn"

### Secondary Triggers
- "fresh vps", "new server", "ubuntu server"
- "ssh key", "server security", "firewall setup"
- "censorship", "bypass firewall", "encrypted connection"

### Contextual Triggers
- User mentions having a VPS with root access
- User asks about VPN protocols (VLESS, Reality, TLS)
- User needs help with proxy configuration

---

## Execution Mode

**Mode:** `interactive-sequential`

The skill executes in a step-by-step manner, requiring user confirmation at critical points.

---

## Required Confirmations

The skill MUST ask for user confirmation before:

1. **Destructive Actions**
   - Locking down SSH (disabling root/password login)
   - Firewall configuration changes
   - Kernel parameter modifications

2. **Installation Steps**
   - 3x-ui panel installation
   - Protocol selection (Reality vs TLS)

3. **Final Steps**
   - Guide file generation
   - fail2ban installation

---

## User Input Requirements

The skill must collect the following information before starting:

### Required (Remote Mode)
1. Server IP address
2. Root password (for initial connection)
3. Desired username (for non-root user)
4. Server nickname (for SSH config)

### Required (Local Mode)
1. Desired username
2. Server nickname

### Optional
1. Domain name (only if user wants VLESS TLS)
2. Custom panel port (default: auto-generated)

---

## Input Validation Rules

### IP Address
- Must be valid IPv4 format
- Must be reachable via ping (optional check)

### Username
- 3-16 characters
- Must start with lowercase letter
- Only lowercase letters and numbers allowed

### Password (if generated)
- Minimum 16 characters
- Must include uppercase, lowercase, numbers, special characters

### Domain (if provided)
- Must be valid domain format
- DNS must resolve to server IP (for TLS mode)

---

## Tool Permissions

**Allowed Tools:**
- `Bash` - Execute shell commands on server
- `Read` - Read files from server
- `Write` - Write files to server and local
- `Edit` - Edit configuration files

**Restricted Actions:**
- Never expose passwords in logs
- Never store sensitive data in plain text (except guide file)
- Never execute unverified scripts from unknown sources

---

## Error Handling

### Connection Lost
If SSH connection drops:
1. Inform user
2. Attempt reconnection
3. If reconnection fails, provide manual recovery steps

### Step Failure
If any step fails:
1. Display error message with possible causes
2. Offer rollback option
3. Provide manual fix instructions

### Rollback Available
The skill supports rollback for:
- User creation
- SSH key installation
- Firewall changes
- Package installations

---

## Output Format

### Progress Indicators
Use the following format for status updates:

```
[1/22] ✓ SSH key generated
[2/22] ⏳ Connecting to server...
[3/22] ✗ Connection failed - retrying...
```

### Status Symbols
- `✓` - Success
- `✗` - Error/Failure
- `⏳` - In Progress
- `!` - Warning
- `→` - Next step

### Color Coding (if supported)
- Green - Success
- Red - Error
- Yellow - Warning
- Blue - Info

---

## Language Support

**Primary:** English  
**Secondary:** Russian (README.ru.md)

The skill should detect user language and respond accordingly.

---

## File Paths

### Local Files
- SSH keys: `~/.ssh/{nickname}_key`
- SSH config: `~/.ssh/config`
- Guide file: `~/vpn-{nickname}-guide.md`

### Remote Files
- Authorized keys: `/home/{username}/.ssh/authorized_keys`
- 3x-ui database: `/etc/x-ui/x-ui.db`
- 3x-ui config: `/etc/x-ui/`
- Xray binary: `/usr/local/x-ui/bin/`

---

## Security Rules

1. **NEVER** log or display passwords in plain text
2. **NEVER** commit guide files to version control
3. **ALWAYS** verify SSH key before locking down access
4. **ALWAYS** use HTTPS/SSH tunnels for panel access
5. **ALWAYS** generate strong random passwords

---

## Post-Installation

After successful installation, the skill should:

1. Generate comprehensive guide file
2. Verify all services are running
3. Test VPN connection (if possible)
4. Provide troubleshooting tips
5. Offer to set up automatic backups

---

## Support & Updates

**Repository:** https://github.com/GilGameshx1/3x-ui-skill  
**Issues:** https://github.com/GilGameshx1/3x-ui-skill/issues
