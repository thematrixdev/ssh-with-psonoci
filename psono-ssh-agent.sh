#!/usr/bin/env bash
# psono-ssh-agent — manages an ssh-agent with keys loaded from Psono

set -uo pipefail

CONFIG="${PSONO_AGENT_CONFIG:-$HOME/.config/psono-agent/config.json}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"; }

expand_path() { echo "${1/#\~/$HOME}"; }

SOCKET_PATH=$(expand_path "$(jq -r '.socket_path' "$CONFIG")")
CACHE_DIR="$HOME/.cache/psono-agent"
REFRESH_INTERVAL=$(jq -r '.refresh_interval // 300' "$CONFIG")

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

# Remove stale socket
rm -f "$SOCKET_PATH"

# Start ssh-agent; eval captures SSH_AGENT_PID
eval "$(ssh-agent -a "$SOCKET_PATH")" >/dev/null
log INFO "ssh-agent started (pid $SSH_AGENT_PID) on $SOCKET_PATH"

cleanup() {
    log INFO "Shutting down..."
    kill "$SSH_AGENT_PID" 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    exit 0
}
trap cleanup SIGTERM SIGINT

load_keys() {
    local count=0
    local num_accounts
    local cache_obj='{}'
    num_accounts=$(jq '.accounts | length' "$CONFIG")

    for i in $(seq 0 $((num_accounts - 1))); do
        local name psono_cfg secrets secret_ids
        name=$(jq -r ".accounts[$i].name" "$CONFIG")
        psono_cfg=$(expand_path "$(jq -r ".accounts[$i].psono_config" "$CONFIG")")

        if ! secrets=$(psonoci -c "$psono_cfg" api-key secrets 2>/dev/null); then
            log ERROR "Failed to fetch secrets for '$name'"
            continue
        fi

        # Build cache: title → { notes, secret_id, psono_config }
        cache_obj=$(echo "$secrets" | jq --arg cfg "$psono_cfg" --argjson existing "$cache_obj" '
            reduce to_entries[] as $e ($existing;
                .[$e.value.title] = {
                    notes: ($e.value.notes // ""),
                    secret_id: $e.key,
                    psono_config: $cfg
                }
            )
        ')

        while IFS= read -r secret_id; do
            local title
            title=$(echo "$secrets" | jq -r ".\"$secret_id\".title // \"${secret_id:0:8}\"")

            if psonoci -c "$psono_cfg" ssh add "$secret_id" \
                --ssh-auth-sock-path "$SOCKET_PATH" >/dev/null 2>&1; then
                log INFO "Loaded [$name] $title"
                count=$((count + 1))

                # Cache public key for IdentityFile matching
                ( umask 077 && psonoci -c "$psono_cfg" secret get "$secret_id" ssh_key_public \
                    > "$CACHE_DIR/$secret_id.pub" 2>/dev/null ) || true
            else
                log ERROR "Failed to load [$name] $title"
            fi
        done < <(echo "$secrets" | jq -r 'keys[]')
    done

    # Write cache atomically (owner-only)
    ( umask 077 && echo "$cache_obj" > "$CACHE_DIR/secrets.json.tmp" )
    mv -f "$CACHE_DIR/secrets.json.tmp" "$CACHE_DIR/secrets.json"
    ( umask 077 && echo "$SOCKET_PATH" > "$CACHE_DIR/socket_path" )
    log INFO "Total: $count key(s) loaded, cache written"
}

while true; do
    log INFO "Loading keys from Psono..."
    load_keys
    sleep "$REFRESH_INTERVAL"
done
