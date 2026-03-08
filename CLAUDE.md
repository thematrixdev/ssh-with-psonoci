# ssh-with-psonoci

SSH key management backed by Psono. Private keys stay in Psono, never on disk.

## Architecture

Two components:

1. **`psono-ssh-agent.sh`** — systemd daemon that runs a real `ssh-agent` loaded with all Psono SSH keys. Keys auto-expire via `--key-lifetime`; daemon refreshes before expiry.

2. **`ssh`** (wrapper) — intercepts `ssh` invocations, matches host alias against Psono secret `title`, parses `notes` as ssh_config directives (`HostName`, `Port`, `User`, `ProxyCommand`, etc.), starts a temp single-key agent per connection. Falls through to `/usr/bin/ssh` if no match.

## Key Files

| File | Purpose |
|------|---------|
| `psono-ssh-agent.sh` | Background daemon (→ `~/.local/bin/`) |
| `ssh` | SSH wrapper (→ `~/.local/bin/`) |
| `config.json` | Account list + agent settings (→ `~/.config/psono-agent/`) |
| `psono-ssh-agent.service` | Systemd unit (→ `~/.config/systemd/user/`) |
| `setup.sh` | Interactive first-time setup |
| `psonoci.toml.example` | Template for psonoci credentials |

## Conventions

- Shell: bash (no Python dependencies)
- JSON parsing: `jq`
- Psono CLI: `psonoci` (v0.5+)
- Psono secret `title` = SSH Host alias; `notes` = ssh_config directives (one per line, `Key Value` format)
- Notes lines without a space are silently skipped (backward compat)
- Credential files (`~/.config/psonoci/*.toml`) must be chmod 600 and must never be committed

## Common Tasks

- **Add a host**: Create an SSH Key secret in Psono with `title` = host alias, `notes` = ssh_config directives
- **Deploy changes**: Copy scripts to `~/.local/bin/`, service to `~/.config/systemd/user/`, then `systemctl --user restart psono-ssh-agent`
- **Test**: `ssh <host-alias>` or `SSH_AUTH_SOCK=~/.ssh/psono-agent.sock ssh-add -l`
- **Push**: `GIT_SSH_COMMAND="/usr/bin/ssh -i ~/.ssh/keys/github.com" git push` (until github.com key is in Psono)
