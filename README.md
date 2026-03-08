# psono-ssh-agent

SSH key management backed by [Psono](https://psono.com) password manager.

Private keys never touch disk — fetched from Psono on demand and held only in memory.

## How It Works

Two components work together:

### 1. `psono-ssh-agent.py` — Background Daemon

Manages a real `ssh-agent` process loaded with all SSH keys from configured Psono accounts.

- Starts `ssh-agent` bound to a fixed socket (`~/.ssh/psono-agent.sock`)
- Fetches all SSH key secrets from each Psono account via `psonoci ssh add`
- Keys are loaded with `--key-lifetime` so they auto-expire; daemon re-adds them before expiry
- Runs as a systemd user service

### 2. `~/.local/bin/ssh` — SSH Wrapper

Intercepts every `ssh` invocation to load only the relevant key for the target host.

```
ssh openwrt
  │
  ├─ lookup Psono: title = "openwrt"
  ├─ resolve HostName from notes field: "192.168.50.1"
  ├─ start temp ssh-agent (/tmp/psono-ssh-PID.sock)
  ├─ psonoci ssh add <secret_id>  ← only this one key
  ├─ /usr/bin/ssh -o IdentityAgent=/tmp/psono-ssh-PID.sock 192.168.50.1
  └─ cleanup: kill temp agent, delete socket
```

The destination server sees only **one** public key probe, not all keys in the agent.

If no Psono secret matches the host, the wrapper passes through to `/usr/bin/ssh` unchanged.

## Psono Secret Format

Each SSH key secret must be configured as follows:

| Psono Field | SSH Meaning | Example |
|-------------|-------------|---------|
| `title`     | `Host` alias (what you type) | `openwrt` |
| `notes`     | `HostName` (actual IP or FQDN) | `192.168.50.1` |
| SSH Key     | The private/public key pair | ED25519, RSA, ECDSA |

If `notes` is empty, the host alias is used as-is for the connection.

Multiple Psono accounts are supported. The wrapper searches all accounts in order.

## Files

| File | Purpose |
|------|---------|
| `~/.local/bin/psono-ssh-agent.py` | Background daemon |
| `~/.local/bin/ssh` | SSH wrapper |
| `~/.config/psono-agent/config.json` | Configuration |
| `~/.config/systemd/user/psono-ssh-agent.service` | Systemd unit |
| `~/.config/psonoci/personal.toml` | Psono credentials (personal) |
| `~/.config/psonoci/work.toml` | Psono credentials (work) |

## Configuration

`~/.config/psono-agent/config.json`:

```json
{
  "accounts": [
    {"name": "personal", "psono_config": "~/.config/psonoci/personal.toml"},
    {"name": "work",     "psono_config": "~/.config/psonoci/work.toml"}
  ],
  "socket_path": "~/.ssh/psono-agent.sock",
  "cache_ttl": 300,
  "log_level": "INFO"
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `accounts` | — | List of Psono accounts with their `psonoci` config paths |
| `socket_path` | `~/.ssh/psono-agent.sock` | Unix socket for the background agent |
| `cache_ttl` | `300` | Key lifetime in seconds; daemon refreshes before expiry |
| `log_level` | `INFO` | Logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

`~/.config/psonoci/*.toml` — one file per Psono account:

```toml
version = "1"

[psono_settings]
api_key_id         = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
api_secret_key_hex = "xxxx...64 hex chars...xxxx"
server_url         = "https://your-psono-server/"

[http_options]
timeout                          = 60
max_redirects                    = 0
use_native_tls                   = false
danger_disable_tls_verification  = false
```

The Psono API key must have **read access** to all SSH key secrets you want to use. `restrict_to_secrets` can be set to only expose SSH keys to this API key.

## Installation

### Dependencies

```bash
# psonoci
curl -L https://github.com/meldron/psonoci/releases/latest/download/psonoci-linux-x86_64 \
  -o ~/.local/bin/psonoci && chmod +x ~/.local/bin/psonoci

# Python cryptography library (for psonoci ssh add)
pip install cryptography
```

### Setup

```bash
# 1. Create config directory
mkdir -p ~/.config/psono-agent ~/.config/psonoci

# 2. Place config files (see Configuration above)

# 3. Make scripts executable
chmod +x ~/.local/bin/psono-ssh-agent.py ~/.local/bin/ssh

# 4. Ensure ~/.local/bin is before /usr/bin in PATH
#    Add to ~/.bashrc or ~/.zshrc if not already present:
#    export PATH="$HOME/.local/bin:$PATH"

# 5. Enable and start the background daemon
systemctl --user daemon-reload
systemctl --user enable --now psono-ssh-agent

# 6. Verify keys are loaded
SSH_AUTH_SOCK=~/.ssh/psono-agent.sock ssh-add -l
```

### `~/.ssh/config`

Add a global `IdentityAgent` as fallback for hosts not managed by Psono:

```sshconfig
Host *
    IdentityAgent ~/.ssh/psono-agent.sock
```

The SSH wrapper overrides this with a single-key temp agent for matched hosts.

## Security Properties

- **Private keys never written to disk** — loaded into agent memory only
- **Per-connection key isolation** — temp agent holds exactly one key per SSH session
- **Destination server sees one key probe** — no fingerprint leakage of unrelated keys
- **Keys auto-expire** — `--key-lifetime` ensures no long-lived key material in memory
- **Psono credentials protected** — `psonoci` config files are `chmod 600`

## Troubleshooting

```bash
# Check daemon status and logs
systemctl --user status psono-ssh-agent
journalctl --user -u psono-ssh-agent -f

# Test Psono connectivity
psonoci -c ~/.config/psonoci/work.toml api-key secrets | jq '[to_entries[] | {title: .value.title}]'

# Verify wrapper is intercepting ssh
which ssh   # should show ~/.local/bin/ssh
```
