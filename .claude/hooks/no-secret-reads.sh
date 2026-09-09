#!/bin/sh
# PreToolUse hook: refuse Bash commands that would print secrets to the
# transcript. Reads the hook payload on stdin and answers with a PreToolUse
# permission decision.
#
# This exists because permission `deny` rules only cover host paths reached
# through the Read tool, and the leaks it is meant to stop did not look like
# that: they came from Bash, reading a config file *inside a container*
# (`docker exec pi-kavita sh -c 'cat /config/appsettings.json'`), where no
# host-path rule can see them.
#
# Fails closed. A security control that silently stops working is worse than
# no control, so a missing jq or an unreadable payload denies rather than
# waves the command through.

set -eu

DENY_HINT='Read key NAMES only (jq -r "keys[]" FILE, grep -oE "^[A-Za-z_]+=" FILE),
add --quiet to `docker compose config`, redact with sed before printing, or ask
the user to paste the value they want you to see.'

# permissionDecision=deny is what actually blocks the call; the reason is shown
# to the model. jq -Rs does the JSON string escaping, so the message may contain
# quotes and newlines.
deny() {
    reason="$1 $DENY_HINT"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
        "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
}

command -v jq >/dev/null 2>&1 || deny 'Cannot vet this command for secret exposure: jq is unavailable.'

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" || cmd=""

[ -n "$cmd" ] || exit 0

# Match against what the shell will EXECUTE, not against data that merely rides
# along in the same string. A heredoc body is stdin for the receiving command,
# so a commit message or a doc paragraph about secret handling is text, not a
# read - and without this the hook blocks its own commit, which is how the need
# for this was discovered.
#
# The exception is a heredoc fed to a shell (`sh <<EOF`), where the body IS
# executed. Those bodies stay in scope.
strip_heredoc_bodies() {
    awk '
        BEGIN { skip = 0 }
        skip {
            if ($0 == marker) { skip = 0 }
            next
        }
        {
            print
            line = $0
            if (line ~ /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/ \
                && line !~ /(^|[ \t;&|('"'"'"])(sh|bash|zsh|dash|ksh)([ \t]|$)/) {
                body = line
                sub(/^.*<<-?[ \t]*/, "", body)
                gsub(/['"'"'"]/, "", body)
                sub(/[ \t].*$/, "", body)
                if (body != "") { marker = body; skip = 1 }
            }
        }
    '
}

cmd="$(printf '%s\n' "$cmd" | strip_heredoc_bodies)"
[ -n "$cmd" ] || exit 0

# Leading context for a command word. The quotes matter: the leak that prompted
# this hook was `docker exec pi-kavita sh -c 'cat /config/appsettings.json'`,
# where the reader is preceded by a single quote rather than whitespace, so
# without them every `sh -c '...'` wrapper walks straight through. Defined here
# because the checks below all need it. The '"'"' is the shell dance for a
# literal single quote.
READER_LEAD='(^|[ \t;&|(`$'"'"'"])'

# `docker compose config` renders every env_file inline, so its output carries
# ntfy tokens and database passwords. --quiet validates without printing.
if printf '%s' "$cmd" | grep -qE 'docker(-| )compose([ \t]+[^;&|]*)?[ \t]+config'; then
    printf '%s' "$cmd" | grep -qE 'config([ \t]+[^;&|]*)?[ \t]+(--quiet|-q)([ \t]|$)' \
        || deny '`docker compose config` inlines every env_file (passwords, tokens) into its output.'
fi

# A container's full environment is where entrypoint-exported secrets live.
if printf '%s' "$cmd" | grep -qE 'docker[ \t]+inspect[^;&|]*(Config\.Env|\.Env[}] )'; then
    deny 'docker inspect .Config.Env prints the container environment, secrets included.'
fi
if printf '%s' "$cmd" | grep -qE "$READER_LEAD"'(printenv|env)([ \t]*$|[ \t]*['"'"'"]|[ \t]+[|>])'; then
    deny 'A bare printenv/env dumps the whole environment. Name the one variable you need instead.'
fi

# Anything that prints file content. sed/awk/grep/jq are in here deliberately:
# a targeted extraction is exactly how the Kavita TokenKey leaked - the redaction
# keyed on the wrong field name, matched nothing, and printed the file whole.
READERS="$READER_LEAD"'(cat|bat|tac|nl|less|more|head|tail|strings|xxd|od|base64|sed|awk|grep|egrep|rg|jq|yq|dd|tee|php|node|python3?)([ \t]|$)'

# Paths that hold real secrets. The `.template` and `.dist` forms are
# deliberately NOT matched - they carry placeholders, and reading them is how
# the rendering scripts get understood.
SECRETS='(\.env([ \t"'"'"';&|)]|$)|/[A-Za-z0-9_.-]+\.env([ \t"'"'"';&|)]|$)|authelia-config/secrets|homepage/secrets|/config/secrets/|appsettings\.json|immich-oauth-config|configuration\.yml([ \t"'"'"';&|)]|$)|config\.php([ \t"'"'"';&|)]|$)|oidc_[a-z-]+_secret|_secret\.txt|/secrets/|\.pem([ \t"'"'"';&|)]|$)|\.key([ \t"'"'"';&|)]|$)|id_rsa|credentials)'

if printf '%s' "$cmd" | grep -qE "$READERS" && printf '%s' "$cmd" | grep -qE "$SECRETS"; then
    deny 'This command reads a file that holds real secrets.'
fi

exit 0
