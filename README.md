# psono-ssh-agent

SSH key management backed by [Psono](https://psono.com) password manager.

Private keys never touch disk — fetched from Psono on demand and held only in memory.

## How It Works

Two components work together:

### 1. `psono-ssh-agent.sh` — Background Daemon

Manages a real `ssh-agent` process loaded with all SSH keys from configured Psono accounts.

- Starts `ssh-agent` bound to a fixed socket (`~/.ssh/psono-agent.sock`)
- Fetches all SSH key secrets from each Psono account via `psonoci ssh add`
- Writes a local cache (`~/.cache/psono-agent/`) with secrets metadata and public keys for fast wrapper lookups
- Refreshes keys and cache on a configurable interval (`refresh_interval`, default 60s)
- Runs as a systemd user service

### 2. `ssh` — SSH Wrapper

Intercepts every `ssh` invocation to load only the relevant key for the target host.

```
ssh dev-server
  │
  ├─ lookup cache: title = "dev-server"  (instant, from ~/.cache/psono-agent/secrets.json)
  ├─ parse notes → -o HostName=10.0.0.5 -o Port=2222 -o User=ubuntu
  ├─ resolve cached public key → IdentitiesOnly=yes + IdentityFile=<cached .pub>
  ├─ /usr/bin/ssh -o IdentityAgent=~/.ssh/psono-agent.sock -o IdentitiesOnly=yes \
  │    -o IdentityFile=<cached .pub> -o HostName=... -o Port=... -o User=... dev-server
  └─ (falls back to temp single-key agent if daemon is not running)
```

The destination server sees only **one** public key probe, not all keys in the agent.

For `ssh -G` queries (used by IDEs like JetBrains IDEA), the wrapper injects notes and key options without starting an agent, responding instantly from cache.

If no Psono secret matches the host, the wrapper passes through to `/usr/bin/ssh` unchanged.

## Psono Secret Format

Each SSH key secret in Psono:

| Psono Field | Purpose | Example |
|-------------|---------|---------|
| `title`     | SSH Host alias (what you type after `ssh`) | `dev-server` |
| `notes`     | SSH config directives, one per line | see below |
| SSH Key     | The private/public key pair | ED25519, RSA, ECDSA |

The `notes` field uses standard `~/.ssh/config` syntax:

```
HostName 10.0.0.5
Port 2222
User ubuntu
```

Any SSH config directive is supported — `HostName`, `Port`, `User`, `ProxyCommand`, `ForwardAgent`, etc. Each line is passed to SSH as `-o Key=Value`.

**Examples:**

Simple host:
```
HostName 192.168.50.1
User root
```

Host behind Cloudflare Tunnel:
```
HostName dev.dummy.com
Port 22
User ubuntu
ProxyCommand /usr/local/bin/cloudflared access ssh --hostname %h
```

If `notes` is empty, the host alias is used as-is (equivalent to running `ssh <title>` with no extra options).

Multiple Psono accounts are supported. The wrapper searches all accounts in order.

## Files

| File | Purpose |
|------|---------|
| `~/.local/bin/psono-ssh-agent.sh` | Background daemon |
| `~/.local/bin/ssh` | SSH wrapper |
| `~/.config/psono-agent/config.json` | Configuration |
| `~/.config/systemd/user/psono-ssh-agent.service` | Systemd unit |
| `~/.config/psonoci/personal.toml` | Psono credentials (personal) |
| `~/.config/psonoci/work.toml` | Psono credentials (work) |
| `~/.cache/psono-agent/secrets.json` | Cached secrets metadata (auto-generated) |
| `~/.cache/psono-agent/*.pub` | Cached public keys (auto-generated) |
| `~/.config/environment.d/ssh-auth-sock.conf` | Sets SSH_AUTH_SOCK for desktop apps |

## Configuration

`~/.config/psono-agent/config.json`:

```json
{
  "accounts": [
    {"name": "personal", "psono_config": "~/.config/psonoci/personal.toml"},
    {"name": "work",     "psono_config": "~/.config/psonoci/work.toml"}
  ],
  "socket_path": "~/.ssh/psono-agent.sock",
  "refresh_interval": 60,
  "log_level": "INFO"
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `accounts` | — | List of Psono accounts with their `psonoci` config paths |
| `socket_path` | `~/.ssh/psono-agent.sock` | Unix socket for the background agent |
| `refresh_interval` | `60` | Seconds between daemon key refresh cycles |
| `log_level` | `INFO` | Logging level (`INFO`, `WARNING`, `ERROR`) |

`~/.config/psonoci/*.toml` — one file per Psono account:

```toml
version = "1"

[psono_settings]
api_key_id         = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
api_secret_key_hex = "xxxx...64 hex chars...xxxx"
server_url         = "https://your-psono-server/"

[http_options]
timeout                         = 60
max_redirects                   = 0
use_native_tls                  = false
danger_disable_tls_verification = false
```

The Psono API key must have **read access** to all SSH key secrets you want to use. `restrict_to_secrets` can be set to only expose SSH keys to this API key.

## Installation

Run the interactive setup script:

```bash
git clone git@github.com:thematrixdev/ssh-with-psonoci.git
cd ssh-with-psonoci
bash setup.sh
```

The script will guide you through:

1. Checking and installing dependencies (psonoci auto-downloaded if missing)
2. Adding one or more Psono accounts — credentials are tested before saving
3. Writing `~/.config/psono-agent/config.json`
4. Installing scripts to `~/.local/bin/` with correct permissions
5. Checking PATH order and optionally updating `.bashrc` / `.zshrc`
6. Enabling the systemd user service
7. Configuring `SSH_AUTH_SOCK` via `environment.d` and optionally disabling GNOME Keyring SSH agent
8. Optionally updating `~/.ssh/config` with `IdentityAgent` and `IdentitiesOnly`
9. Verifying the agent is running and keys are loaded

The script is safe to re-run — existing files prompt before overwriting, and existing accounts are preserved unless explicitly replaced.

### `~/.ssh/config`

The setup script can add this automatically, or add it manually:

```sshconfig
Host *
    IdentityAgent ~/.ssh/psono-agent.sock
    IdentitiesOnly yes
```

`IdentitiesOnly yes` prevents SSH from trying all agent keys — only keys explicitly specified via `-i` or the wrapper's `-o IdentityFile` are used, avoiding "Too many authentication failures" errors.

## Security Properties

- **Private keys never written to disk** — loaded into agent memory only; cached public keys (`.pub`) contain no sensitive material
- **Single-key authentication** — `IdentitiesOnly` + `IdentityFile` ensures only the matching key is offered per connection
- **Destination server sees one key probe** — no fingerprint leakage of unrelated keys
- **Cache files protected** — `~/.cache/psono-agent/` is `chmod 700`, all files `chmod 600`
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
