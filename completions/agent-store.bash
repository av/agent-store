# shellcheck shell=bash disable=SC2207
# bash completion for agent-store
#
# SC2207 is disabled: compgen -W output is one word per line and the
# COMPREPLY=($(compgen ...)) idiom is standard for completion scripts.
#
# Install: source this file from your ~/.bashrc, or copy it to
#   /usr/share/bash-completion/completions/agent-store
#   (or ~/.local/share/bash-completion/completions/agent-store)

_agent_store() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD - 1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    local commands="init create cr find ls get set unset rm link unlink links ctx context hook schedule"
    local global_opts="--json --help --version -h -V"

    # Locate the subcommand (first non-option word after the program name).
    local cmd="" i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
        -*) ;;
        *)
            cmd="${words[i]}"
            break
            ;;
        esac
    done

    if [[ -z "$cmd" ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi

    case "$cmd" in
    create | cr)
        COMPREPLY=($(compgen -W "--stdin" -- "$cur"))
        ;;
    find | ls)
        case "$prev" in
        --sort)
            COMPREPLY=($(compgen -W "created_at updated_at kind id" -- "$cur"))
            ;;
        --limit) ;;
        *)
            COMPREPLY=($(compgen -W "--timestamps --sort --desc --limit --count" -- "$cur"))
            ;;
        esac
        ;;
    get)
        COMPREPLY=($(compgen -W "--timestamps" -- "$cur"))
        ;;
    hook)
        # Locate the hook subcommand.
        local sub="" j
        for ((j = i + 1; j < cword; j++)); do
            case "${words[j]}" in
            -*) ;;
            *)
                sub="${words[j]}"
                break
                ;;
            esac
        done
        if [[ -z "$sub" ]]; then
            COMPREPLY=($(compgen -W "add ls rm runs" -- "$cur"))
            return
        fi
        case "$sub" in
        add)
            if [[ "$prev" == "add" ]]; then
                COMPREPLY=($(compgen -W "create set unset rm link unlink" -- "$cur"))
            fi
            ;;
        runs)
            [[ "$prev" != "--limit" ]] &&
                COMPREPLY=($(compgen -W "--limit" -- "$cur"))
            ;;
        esac
        ;;
    schedule)
        local sub="" j
        for ((j = i + 1; j < cword; j++)); do
            case "${words[j]}" in
            -*) ;;
            *)
                sub="${words[j]}"
                break
                ;;
            esac
        done
        if [[ -z "$sub" ]]; then
            COMPREPLY=($(compgen -W "add ls rm runs tick enable disable" -- "$cur"))
            return
        fi
        case "$sub" in
        add)
            if [[ "$prev" == "add" ]]; then
                COMPREPLY=($(compgen -W "at every" -- "$cur"))
            fi
            ;;
        runs)
            [[ "$prev" != "--limit" ]] &&
                COMPREPLY=($(compgen -W "--limit" -- "$cur"))
            ;;
        esac
        ;;
    esac
}

complete -F _agent_store agent-store
