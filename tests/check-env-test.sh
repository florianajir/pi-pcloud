#!/bin/sh
# Tests for `make check-env`, the gate `make preflight`/`make install` run
# before anything touches the host.
#
# It shares scripts/lib.sh's env_value_is_safe with install.sh's prompt, so
# this suite is the other half of tests/install-test.sh: the same rule has to
# reject the same values whether they were typed or edited into .env by hand.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
mkdir -p "$APP/scripts"
cp "$REPO_DIR/Makefile" "$APP/"
cp "$REPO_DIR/scripts/lib.sh" "$REPO_DIR/scripts/check-env.sh" "$APP/scripts/"

# shellcheck source=tests/testlib.sh
. "$(dirname "$0")/testlib.sh"

# Every required variable except PASSWORD, which each case below supplies.
write_env() {
    for var in $(sh "$REPO_DIR/scripts/check-env.sh" --list); do
        [ "$var" != PASSWORD ] || continue
        printf '%s=placeholder-value\n' "$var"
    done >"$APP/.env"
    printf 'PASSWORD=%s\n' "$1" >>"$APP/.env"
}

# run_check: accept or reject, with the command's output left in $WORK/out.
run_check() {
    if make -C "$APP" check-env >"$WORK/out" 2>&1; then
        echo accept
    else
        echo reject
    fi
}

# check_value <description> <PASSWORD value> <accept|reject>
check_value() {
    write_env "$2"
    ok "$1" "$(run_check)" "$3"
}

check_value "a plain password"        'hunter2'      accept
check_value "a mid-value backslash"   'hun\ter2'     accept
check_value "punctuation"             'a-b_c.d:e/f'  accept
check_value "a dollar sign"           'hun$ter2'     reject
check_value "a trailing backslash"    'hunter2\'     reject
check_value "a trailing space"        'hunter2 '     reject
check_value "a leading space"         ' hunter2'     reject
check_value "an inline comment"       'hunter2 #x'   reject
check_value "wrapping double quotes"  '"hunter2"'    reject
check_value "wrapping single quotes"  "'hunter2'"    reject
check_value "an empty value"          ''             reject

# A missing .env must be reported, not treated as an empty one.
rm -f "$APP/.env"
ok       "a missing .env is refused" "$(run_check)" reject
contains "  and named"               "$(cat "$WORK/out")" ".env missing"

# A required variable absent from the file must fail by name.
write_env 'hunter2'
grep -v '^HOST_NAME=' "$APP/.env" >"$APP/.env.tmp"
mv "$APP/.env.tmp" "$APP/.env"
ok       "a missing variable is refused" "$(run_check)" reject
contains "  by name"                     "$(cat "$WORK/out")" "HOST_NAME is not set or empty"

# check-env is useless if it cannot reach the rule it enforces.
write_env 'hunter2'
rm -f "$APP/scripts/lib.sh"
ok       "an unreadable lib.sh is refused" "$(run_check)" reject
contains "  and named"                     "$(cat "$WORK/out")" "lib.sh"

finish
