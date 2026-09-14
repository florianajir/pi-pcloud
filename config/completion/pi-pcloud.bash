# bash completion for pi-pcloud.
#
# Both lists come from the command itself (--list-commands reads the Makefile,
# --list-services reads compose/*.yaml), so nothing here has to be updated when a
# command or a service is added.
_pi_pcloud() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "$(pi-pcloud --list-commands 2>/dev/null)" -- "$cur")
        return 0
    fi

    case "$prev" in
        enable | disable)
            mapfile -t COMPREPLY < <(compgen -W "$(pi-pcloud --list-services 2>/dev/null)" -- "$cur")
            ;;
        *) COMPREPLY=() ;;
    esac
}
complete -F _pi_pcloud pi-pcloud
