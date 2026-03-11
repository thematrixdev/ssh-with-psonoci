# Bash completion for psono ssh/scp wrappers
# Re-applies the system SSH/SCP completion and adds Psono host aliases

# Source the system SSH completion (registers _comp_cmd_ssh and _comp_cmd_scp)
if [[ -f /usr/share/bash-completion/completions/ssh ]]; then
    # shellcheck source=/dev/null
    source /usr/share/bash-completion/completions/ssh
fi

# Helper: add Psono host aliases to COMPREPLY
_psono_add_hosts() {
    local cur="$1"
    local secrets_cache="$HOME/.cache/psono-agent/secrets.json"
    if [[ -f "$secrets_cache" ]] && command -v jq &>/dev/null; then
        local psono_hosts
        psono_hosts=$(jq -r 'keys[]' "$secrets_cache" 2>/dev/null)
        if [[ -n "$psono_hosts" ]]; then
            local IFS=$'\n'
            COMPREPLY+=($(compgen -W "$psono_hosts" -- "$cur"))
        fi
    fi
}

# Wrap ssh completion
if declare -F _comp_cmd_ssh &>/dev/null; then
    _psono_ssh() {
        _comp_cmd_ssh "$@"
        local cur="${COMP_WORDS[COMP_CWORD]}"
        [[ "$cur" != -* ]] && _psono_add_hosts "$cur"
    }
    complete -F _psono_ssh ssh
fi

# Wrap scp completion
if declare -F _comp_cmd_scp &>/dev/null; then
    _psono_scp() {
        _comp_cmd_scp "$@"
        local cur="${COMP_WORDS[COMP_CWORD]}"
        # Complete hostnames (not options, not paths, not after colon)
        if [[ "$cur" != -* && "$cur" != *:* && "$cur" != /* && "$cur" != .* && "$cur" != ~* ]]; then
            _psono_add_hosts "$cur"
        fi
    }
    complete -F _psono_scp -o nospace scp
fi
