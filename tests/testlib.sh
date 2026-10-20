#!/bin/sh
# The assertions every suite shares. Source it near the top of a suite:
#
#   # shellcheck source=tests/testlib.sh
#   . "$(dirname "$0")/testlib.sh"
#
# then end the suite with `finish`, whose status is the suite's: a run that
# counted a single failure exits non-zero, so `make test` and CI stop on it.

pass=0
fail=0

# Usage: ok <description> <got> <want>
ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

# Usage: contains <description> <text> <substring>
contains() {
    case "$2" in
        *"$3"*) ok "$1" yes yes ;;
        *) ok "$1" "$2" "(contains) $3" ;;
    esac
}

# Usage: lacks <description> <text> <substring>
lacks() {
    case "$2" in
        *"$3"*) ok "$1" "$2" "(lacks) $3" ;;
        *) ok "$1" yes yes ;;
    esac
}

finish() {
    printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
    [ "$fail" -eq 0 ]
}
