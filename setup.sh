#!/usr/bin/env bash
# setup.sh — First-time (and repeat) setup for psono-ssh-agent

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/psono-agent"
PSONOCI_DIR="$HOME/.config/psonoci"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SSH_CONFIG="$HOME/.ssh/config"
AGENT_SOCK="$HOME/.ssh/psono-agent.sock"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()      { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  !${NC} $*"; }
err()     { echo -e "${RED}  ✗${NC} $*"; }
section() { echo -e "\n${BLUE}▶ $*${NC}"; }
ask()     { echo -en "${BLUE}  ?${NC} $1 "; }

# ── Helpers ───────────────────────────────────────────────────────────────────

confirm() {
    # confirm "Question?" [default: y]
    local default="${2:-y}"
    if [[ "$default" == "y" ]]; then
        ask "$1 [Y/n] "
    else
        ask "$1 [y/N] "
    fi
    read -r reply
    reply="${reply:-$default}"
    [[ "${reply,,}" == "y" ]]
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "Required command not found: $1"
        return 1
    fi
}

# ── 1. Dependencies ───────────────────────────────────────────────────────────

section "Checking dependencies"

all_deps_ok=1

for cmd in jq ssh ssh-agent ssh-add systemctl; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        err "$cmd — not found (install via: sudo apt install ${cmd})"
        all_deps_ok=0
    fi
done

# psonoci — offer to install if missing
if command -v psonoci &>/dev/null; then
    ok "psonoci ($(psonoci --version 2>&1 | head -1))"
else
    warn "psonoci not found"
    if confirm "Download and install psonoci to $BIN_DIR/psonoci?"; then
        mkdir -p "$BIN_DIR"
        ARCH="$(uname -m)"
        case "$ARCH" in
            x86_64)  PSONOCI_ARCH="x86_64" ;;
            aarch64) PSONOCI_ARCH="aarch64" ;;
            *)        err "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        URL="https://get.psono.com/psono/psono-ci/${PSONOCI_ARCH}-linux/psonoci"
        if curl -fsSL "$URL" -o "$BIN_DIR/psonoci" && chmod +x "$BIN_DIR/psonoci"; then
            ok "psonoci installed to $BIN_DIR/psonoci"
        else
            err "Failed to download psonoci"; all_deps_ok=0
        fi
    else
        err "psonoci required — aborting"; exit 1
    fi
fi

[[ $all_deps_ok -eq 0 ]] && { err "Please install missing dependencies and re-run."; exit 1; }

# ── 2. Directories ────────────────────────────────────────────────────────────

section "Creating directories"

for dir in "$CONFIG_DIR" "$PSONOCI_DIR" "$BIN_DIR" "$SYSTEMD_DIR" "$HOME/.ssh"; do
    mkdir -p "$dir"
    ok "$dir"
done
chmod 700 "$HOME/.ssh"

# ── 3. Psono Accounts ─────────────────────────────────────────────────────────

section "Psono accounts"

# Load existing accounts from config.json if present
existing_accounts="[]"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
    existing_accounts=$(jq '.accounts' "$CONFIG_DIR/config.json" 2>/dev/null || echo "[]")
    count=$(echo "$existing_accounts" | jq 'length')
    if [[ $count -gt 0 ]]; then
        ok "Found $count existing account(s):"
        echo "$existing_accounts" | jq -r '.[] | "    • \(.name) (\(.psono_config))"'
    fi
fi

accounts_json="$existing_accounts"

add_account() {
    echo ""
    ask "Account name (e.g. personal, work):"
    read -r acc_name
    [[ -z "$acc_name" ]] && { warn "Empty name, skipping."; return; }

    # Check if already exists
    exists=$(echo "$accounts_json" | jq -r --arg n "$acc_name" '.[] | select(.name == $n) | .name')
    if [[ -n "$exists" ]]; then
        warn "Account '$acc_name' already exists."
        confirm "Overwrite?" n || return
        accounts_json=$(echo "$accounts_json" | jq --arg n "$acc_name" '[.[] | select(.name != $n)]')
    fi

    ask "Psono server URL [https://www.psono.pw/server]:"
    read -r server_url
    server_url="${server_url:-https://www.psono.pw/server}"
    server_url="${server_url%/}/"   # ensure trailing slash

    ask "API key ID (UUID):"
    read -r api_key_id

    ask "API secret key (64-char hex):"
    read -r api_secret_hex

    local toml_path="$PSONOCI_DIR/${acc_name}.toml"

    cat > "$toml_path" <<TOML
version = "1"

[psono_settings]
api_key_id         = "$api_key_id"
api_secret_key_hex = "$api_secret_hex"
server_url         = "$server_url"

[http_options]
timeout                         = 60
max_redirects                   = 0
use_native_tls                  = false
danger_disable_tls_verification = false
TOML
    chmod 600 "$toml_path"

    echo -n "  Testing connection ... "
    if psonoci -c "$toml_path" api-key info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ok "Account '$acc_name' saved to $toml_path"
        accounts_json=$(echo "$accounts_json" | jq \
            --arg name "$acc_name" \
            --arg cfg "~/.config/psonoci/${acc_name}.toml" \
            '. + [{"name": $name, "psono_config": $cfg}]')
    else
        echo -e "${RED}FAILED${NC}"
        err "Could not connect to Psono with these credentials."
        rm -f "$toml_path"
        confirm "Keep credentials and continue anyway?" n && {
            # restore the file
            cat > "$toml_path" <<TOML
version = "1"

[psono_settings]
api_key_id         = "$api_key_id"
api_secret_key_hex = "$api_secret_hex"
server_url         = "$server_url"

[http_options]
timeout                         = 60
max_redirects                   = 0
use_native_tls                  = false
danger_disable_tls_verification = false
TOML
            chmod 600 "$toml_path"
            accounts_json=$(echo "$accounts_json" | jq \
                --arg name "$acc_name" \
                --arg cfg "~/.config/psonoci/${acc_name}.toml" \
                '. + [{"name": $name, "psono_config": $cfg}]')
        }
    fi
}

if confirm "Add a Psono account?"; then
    add_account
    while confirm "Add another account?"; do
        add_account
    done
fi

if [[ $(echo "$accounts_json" | jq 'length') -eq 0 ]]; then
    warn "No accounts configured. The agent will start but load no keys."
fi

# ── 4. Write config.json ──────────────────────────────────────────────────────

section "Writing config.json"

# Preserve existing non-account settings if config exists
refresh_interval=300
log_level="INFO"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
    # Support legacy cache_ttl field from older configs
    refresh_interval=$(jq -r '.refresh_interval // .cache_ttl // 300' "$CONFIG_DIR/config.json")
    log_level=$(jq -r '.log_level // "INFO"' "$CONFIG_DIR/config.json")
fi

jq -n \
    --argjson accounts "$accounts_json" \
    --argjson refresh_interval "$refresh_interval" \
    --arg log_level "$log_level" \
    '{
        accounts:    $accounts,
        socket_path: "~/.ssh/psono-agent.sock",
        refresh_interval:   $refresh_interval,
        log_level:   $log_level
    }' > "$CONFIG_DIR/config.json"
ok "$CONFIG_DIR/config.json"

# ── 5. Install scripts ────────────────────────────────────────────────────────

section "Installing scripts"

install_file() {
    local src="$REPO_DIR/$1"
    local dst="$2"
    local perms="${3:-644}"

    if [[ ! -f "$src" ]]; then
        err "Source not found: $src"
        return 1
    fi

    if [[ -f "$dst" ]] && ! confirm "  $dst already exists. Overwrite?" y; then
        warn "Skipped $dst"
        return
    fi

    cp "$src" "$dst"
    chmod "$perms" "$dst"
    ok "$dst (chmod $perms)"
}

install_file "psono-ssh-agent.sh" "$BIN_DIR/psono-ssh-agent.sh" 755
install_file "ssh"                 "$BIN_DIR/ssh"                755
install_file "scp"                 "$BIN_DIR/scp"                755
install_file "psono-autofill"      "$BIN_DIR/psono-autofill"     755
install_file "psono-ssh-agent.service" "$SYSTEMD_DIR/psono-ssh-agent.service" 644

COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"
mkdir -p "$COMPLETION_DIR"
install_file "ssh-completion.bash" "$COMPLETION_DIR/ssh" 644

# ── 6. PATH check ─────────────────────────────────────────────────────────────

section "Checking PATH"

# Check if ~/.local/bin comes before /usr/bin
path_ok=0
while IFS=: read -ra path_parts; do
    for p in "${path_parts[@]}"; do
        [[ "$p" == "$BIN_DIR" ]] && { path_ok=1; break 2; }
        [[ "$p" == "/usr/bin" ]] && break 2
    done
done <<< "$PATH"

if [[ $path_ok -eq 1 ]]; then
    ok "$BIN_DIR is before /usr/bin in PATH"
else
    warn "$BIN_DIR is not before /usr/bin in PATH"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if grep -q 'LOCAL_BIN\|\.local/bin' "$rc" 2>/dev/null; then
            warn "PATH entry may already exist in $rc — please check manually"
        elif confirm "  Add PATH export to $rc?"; then
            echo '' >> "$rc"
            echo '# psono-ssh-agent: ensure ~/.local/bin takes priority' >> "$rc"
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            ok "Added to $rc (effective on next login or: source $rc)"
        fi
    done
fi

# ── 7. Systemd service ────────────────────────────────────────────────────────

section "Systemd user service"

systemctl --user daemon-reload

if systemctl --user is-enabled psono-ssh-agent &>/dev/null; then
    ok "psono-ssh-agent.service already enabled"
    if confirm "  Restart service?"; then
        systemctl --user restart psono-ssh-agent
        ok "Service restarted"
    fi
else
    systemctl --user enable --now psono-ssh-agent
    ok "psono-ssh-agent.service enabled and started"
fi

# ── 8. SSH_AUTH_SOCK environment ───────────────────────────────────────────

section "SSH_AUTH_SOCK environment"

ENV_D_DIR="$HOME/.config/environment.d"
ENV_D_FILE="$ENV_D_DIR/ssh-auth-sock.conf"

mkdir -p "$ENV_D_DIR"

if [[ -f "$ENV_D_FILE" ]] && grep -q "psono-agent" "$ENV_D_FILE" 2>/dev/null; then
    ok "$ENV_D_FILE already configured"
else
    echo "SSH_AUTH_SOCK=$AGENT_SOCK" > "$ENV_D_FILE"
    ok "$ENV_D_FILE created"
fi

# Disable GCR SSH agent if active (it overrides SSH_AUTH_SOCK)
if systemctl --user is-active gcr-ssh-agent.socket &>/dev/null; then
    warn "gcr-ssh-agent (GNOME Keyring SSH) is active and overrides SSH_AUTH_SOCK"
    if confirm "  Disable gcr-ssh-agent so Psono agent is used instead?"; then
        systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service &>/dev/null
        ok "gcr-ssh-agent masked"
    fi
elif systemctl --user is-enabled gcr-ssh-agent.socket &>/dev/null 2>&1; then
    warn "gcr-ssh-agent is enabled (may override SSH_AUTH_SOCK on next login)"
    if confirm "  Disable gcr-ssh-agent so Psono agent is used instead?"; then
        systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service &>/dev/null
        ok "gcr-ssh-agent masked"
    fi
else
    ok "gcr-ssh-agent not active"
fi

# ── 9. ~/.ssh/config ─────────────────────────────────────────────────────────

section "~/.ssh/config"

if [[ -f "$SSH_CONFIG" ]] && grep -q "IdentityAgent.*psono-agent" "$SSH_CONFIG" 2>/dev/null; then
    ok "IdentityAgent already present in $SSH_CONFIG"
else
    if confirm "  Add 'IdentityAgent ~/.ssh/psono-agent.sock' to Host * in $SSH_CONFIG?"; then
        # Prepend to existing config
        tmp=$(mktemp)
        printf 'Host *\n    IdentityAgent ~/.ssh/psono-agent.sock\n\n' > "$tmp"
        [[ -f "$SSH_CONFIG" ]] && cat "$SSH_CONFIG" >> "$tmp"
        mv "$tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        ok "$SSH_CONFIG updated"
    fi
fi

# ── 10. Verification ──────────────────────────────────────────────────────────

section "Verification"

echo -n "  Waiting for agent socket ... "
for i in $(seq 1 10); do
    [[ -S "$AGENT_SOCK" ]] && break
    sleep 1
done

if [[ -S "$AGENT_SOCK" ]]; then
    echo -e "${GREEN}OK${NC}"
    key_count=$(SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l 2>/dev/null | grep -c 'SHA256' || true)
    ok "Agent running — $key_count key(s) loaded"
    SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l 2>/dev/null | sed 's/^/    /' || true
else
    echo -e "${RED}NOT FOUND${NC}"
    err "Agent socket not found at $AGENT_SOCK"
    err "Check logs: journalctl --user -u psono-ssh-agent -n 20"
fi

echo -n "  SSH wrapper: "
wrapper=$(command -v ssh 2>/dev/null || true)
if [[ "$wrapper" == "$BIN_DIR/ssh" ]]; then
    echo -e "${GREEN}$wrapper${NC}"
    ok "SSH wrapper active"
else
    echo -e "${YELLOW}$wrapper${NC}"
    warn "SSH wrapper not intercepting — ensure $BIN_DIR is first in PATH and re-login"
fi

echo ""
ok "Setup complete."
