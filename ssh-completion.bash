# Bash completion for psono ssh wrapper
# Re-applies the system SSH completion and adds Psono host aliases

# Source the system SSH completion (registers _comp_cmd_ssh for ssh)
if [[ -f /usr/share/bash-completion/completions/ssh ]]; then
    # shellcheck source=/dev/null
    source /usr/share/bash-completion/completions/ssh
fi

# If _comp_cmd_ssh exists, wrap it to also inject Psono host aliases
if declare -F _comp_cmd_ssh &>/dev/null; then
    _psono_ssh() {
        # Run the standard SSH completion first
        _comp_cmd_ssh "$@"

        # Add Psono secret titles as host completions
        local config="$HOME/.config/psono-agent/config.json"
        if [[ -f "$config" ]] && command -v jq &>/dev/null && command -v psonoci &>/dev/null; then
            local cur="${COMP_WORDS[COMP_CWORD]}"
            # Only complete hostnames (skip if current word starts with -)
            if [[ "$cur" != -* ]]; then
                local cache_file="$HOME/.cache/psono-ssh-hosts"
                local cache_max_age=300  # 5 minutes

                # Refresh cache if stale or missing
                if [[ ! -f "$cache_file" ]] || \
                   [[ $(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) )) -gt $cache_max_age ]]; then
                    mkdir -p "$HOME/.cache"
                    local hosts=""
                    local num_accounts
                    num_accounts=$(jq '.accounts | length' "$config" 2>/dev/null) || return
                    for i in $(seq 0 $((num_accounts - 1))); do
                        local psono_cfg
                        psono_cfg=$(jq -r ".accounts[$i].psono_config" "$config")
                        psono_cfg="${psono_cfg/#\~/$HOME}"
                        local titles
                        titles=$(psonoci -c "$psono_cfg" api-key secrets 2>/dev/null | \
                            jq -r '[.[].title // empty] | .[]' 2>/dev/null) || continue
                        hosts+="$titles"$'\n'
                    done
                    echo "$hosts" > "$cache_file"
                fi

                local psono_hosts
                psono_hosts=$(cat "$cache_file" 2>/dev/null)
                if [[ -n "$psono_hosts" ]]; then
                    local IFS=$'\n'
                    COMPREPLY+=($(compgen -W "$psono_hosts" -- "$cur"))
                fi
            fi
        fi
    }

    complete -F _psono_ssh ssh
fi
