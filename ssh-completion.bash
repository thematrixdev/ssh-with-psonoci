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
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [[ "$cur" != -* ]]; then
            local secrets_cache="$HOME/.cache/psono-agent/secrets.json"
            if [[ -f "$secrets_cache" ]] && command -v jq &>/dev/null; then
                local psono_hosts
                psono_hosts=$(jq -r 'keys[]' "$secrets_cache" 2>/dev/null)
                if [[ -n "$psono_hosts" ]]; then
                    local IFS=$'\n'
                    COMPREPLY+=($(compgen -W "$psono_hosts" -- "$cur"))
                fi
            fi
        fi
    }

    complete -F _psono_ssh ssh
fi
