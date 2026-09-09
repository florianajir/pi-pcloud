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

    if printf '%s' "$payload" | "$HOOK" 2>&1 | grep -q '"deny"'; then
        got=deny
    else
        got=allow
    fi

    if [ "$got" = "$expect" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL want=%-5s got=%-5s %s\n' "$expect" "$got" "$command_text"
    fi
done < "$CASES"

printf 'no-secret-reads.test.sh: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
