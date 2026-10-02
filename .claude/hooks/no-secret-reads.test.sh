#!/bin/sh
# Regression test for no-secret-reads.sh. Reads its cases from the sibling
# .cases file rather than taking them as arguments, because the hook inspects
# the command line it is invoked from: a harness that passed `cat .env` as an
# argument would be blocked by the very hook it is testing.

set -eu

HOOK_DIR="$(dirname "$0")"
HOOK="$HOOK_DIR/no-secret-reads.sh"
CASES="$HOOK_DIR/no-secret-reads.cases"

[ -x "$HOOK" ] || { echo "no-secret-reads.test.sh: $HOOK is not executable" >&2; exit 1; }
[ -f "$CASES" ] || { echo "no-secret-reads.test.sh: $CASES not found" >&2; exit 1; }

passed=0
failed=0

# The cases file spells newlines as a literal \n so a heredoc case fits on one
# line; printf '%b' turns them back into real newlines.
while IFS='	' read -r expect command_text; do
    case "$expect" in ''|\#*) continue ;; esac
    [ -n "$command_text" ] || continue

    real_command="$(printf '%b' "$command_text")"
    payload="$(jq -nc --arg c "$real_command" '{tool_name:"Bash",tool_input:{command:$c}}')"

    # The status counts too: exit 2 blocks the call, so a hook that crashed on
    # an ordinary command would otherwise pass every allow case as a deny-free
    # run while refusing all of them in use.
    status=0
    output="$(printf '%s' "$payload" | "$HOOK" 2>&1)" || status=$?
    case "$output" in
        *'"deny"'*) got=deny ;;
        *) got=allow ;;
    esac
    [ "$status" -eq 0 ] || got="exit$status"

    if [ "$got" = "$expect" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL want=%-5s got=%-5s %s\n' "$expect" "$got" "$command_text"
    fi
done < "$CASES"

# Failure modes no command case can express. Claude Code lets a call through
# on any exit other than 2 that prints no decision, so a payload the hook cannot
# parse must still deny, and a crash - no awk on PATH, a grep that fails - must
# exit 2 rather than pass silently.
expect() {
    if [ "$2" = "$3" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL want=%-5s got=%-5s %s\n' "$2" "$3" "$1"
    fi
}

if printf 'not json' | "$HOOK" 2>/dev/null | grep -q '"deny"'; then got=deny; else got=allow; fi
expect "a payload that is not JSON" deny "$got"

no_awk="$(mktemp -d)"
for tool in jq cat grep sed cut; do ln -s "$(command -v "$tool")" "$no_awk/$tool"; done
status=0
printf '{"tool_input":{"command":"git status"}}' | PATH="$no_awk" "$HOOK" >/dev/null 2>&1 || status=$?
rm -rf "$no_awk"
expect "a crash (no awk on PATH)" 2 "$status"

# A grep that fails reads as "no match" in an `if`; the hook must not take it so.
broken_grep="$(mktemp -d)"
for tool in jq cat awk sed cut tr; do ln -s "$(command -v "$tool")" "$broken_grep/$tool"; done
printf '#!/bin/sh\nexit 2\n' > "$broken_grep/grep"
chmod +x "$broken_grep/grep"
status=0
printf '{"tool_input":{"command":"cat .env"}}' | PATH="$broken_grep" "$HOOK" >/dev/null 2>&1 || status=$?
rm -rf "$broken_grep"
expect "a grep that fails (status 2)" 2 "$status"

# Past 50 recursive reads the hook refuses rather than risk its timeout.
walks=""
i=0
while [ "$i" -le 50 ]; do
    walks="$walks
grep -rn token compose --exclude='*.env' --exclude-dir=secrets"
    i=$((i + 1))
done
payload="$(jq -nc --arg c "$walks" '{tool_name:"Bash",tool_input:{command:$c}}')"
if printf '%s' "$payload" | "$HOOK" 2>/dev/null | grep -q '"deny"'; then got=deny; else got=allow; fi
expect "51 recursive reads in one command" deny "$got"

printf 'no-secret-reads.test.sh: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
