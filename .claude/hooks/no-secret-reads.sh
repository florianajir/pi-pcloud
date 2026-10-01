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

# occ config:*:get prints a key's raw value to stdout - no file path, so the
# SECRETS check below misses it. This is how the Redis password leaked.
if printf '%s' "$cmd" | grep -qE 'occ[ \t]+config:(system|app):get[ \t]+[^;&|]*(redis|password|secret|token|dbpassword|apikey|api_key|smtppassword|s3\.[a-z_]*key)'; then
    deny 'occ config:*:get prints the raw stored value - this key looks secret-shaped.'
fi

# Anything that prints file content. sed/awk/grep/jq are in here deliberately:
# a targeted extraction is exactly how the Kavita TokenKey leaked - the redaction
# keyed on the wrong field name, matched nothing, and printed the file whole.
READER_WORDS='(cat|bat|tac|nl|less|more|head|tail|strings|xxd|od|base64|sed|awk|grep|egrep|rg|jq|yq|dd|tee|php|node|python3?)'
READERS="$READER_LEAD$READER_WORDS"'([ \t]|$)'

# Paths that hold real secrets. The `.template` and `.dist` forms are
# deliberately NOT matched - they carry placeholders, and reading them is how
# the rendering scripts get understood.
SECRETS='(\.env([ \t"'"'"';&|)]|$)|/[A-Za-z0-9_.-]+\.env([ \t"'"'"';&|)]|$)|authelia-config/secrets|homepage/secrets|/config/secrets/|appsettings\.json|immich-oauth-config|configuration\.yml([ \t"'"'"';&|)]|$)|config\.php([ \t"'"'"';&|)]|$)|oidc_[a-z-]+_secret|_secret\.txt|/secrets/|\.pem([ \t"'"'"';&|)]|$)|\.key([ \t"'"'"';&|)]|$)|id_rsa|credentials)'

# Documentation is not a secret. config/homepage/SECRETS.md used to live inside
# the directory it documents, where this rule made it unreadable and
# unwritable - which is how a stale compose.yaml reference survived a
# repository-wide sweep: the guard, not the sweep, was the reason. That page
# has since moved out, and the deny rules in .claude/settings.json still cover
# the whole directory, so a doc under a secrets/ path stays unreachable through
# the Read and Edit tools whatever this says. This is the Bash half only.
#
# Markdown paths are REMOVED before the secret test rather than exempted after
# it, so a command naming a .md *and* a real secret is still denied on the
# secret: `cat .../README.md .../immich.key` keeps the .key and is refused.
# The reader test still runs against the original command.
strip_doc_paths() {
    sed -E 's#[^[:space:];&|()"'"'"']*\.(md|markdown)([[:space:];&|)"'"'"']|$)#\2#g'
}

# A recursive reader names no secret path, so everything above sees only a
# directory: `grep -rn trilium config/agentgateway/` printed agentgateway.env's
# values on 2026-10-01. A reader that walks a tree must therefore say what it
# leaves out, and *.env alone is not enough - config/homepage/secrets/ holds API
# keys with no extension at all. GNU grep's --exclude-dir also applies to a
# directory given on the command line, so naming a secrets/ dir directly is
# covered by the same exclusion.
RECURSIVE_READERS="$READER_LEAD"'((grep|egrep|fgrep)([ \t]+[^;&|]*)?[ \t]+(-[A-Za-z0-9]*[rR][A-Za-z0-9]*|--recursive|--dereference-recursive|--directories=recurse|-d[ \t]*recurse)([ \t]|$)|rg([ \t]|$)|find[ \t][^;&|]*[ \t]-(exec|execdir|ok|okdir)[ \t]+([^;&|]*[ \t'"'"'"])?'"$READER_WORDS"'([ \t]|$)|find[ \t][^;&]*\|[ \t]*xargs([ \t]+[^;&|]*)?[ \t]+'"$READER_WORDS"'([ \t]|$))'

QUOTE='['"'"'"]?'
ENV_EXCLUDED='(--exclude(=|[ \t]+)'"$QUOTE"'|(-g|--glob|--iglob)(=|[ \t]+)'"$QUOTE"'!|(!|\\!|-not)[ \t]+-i?name[ \t]+'"$QUOTE"')\\?\*\.env'"$QUOTE"'([ \t;&|)]|$)'
SECRET_DIRS_EXCLUDED='(--exclude-dir(=|[ \t]+)'"$QUOTE"'secrets|(-g|--glob|--iglob)(=|[ \t]+)'"$QUOTE"'!(\*\*/)?secrets(/\*\*)?/?|(!|\\!|-not)[ \t]+-path[ \t]+'"$QUOTE"'\*/secrets(/\*)?|-path[ \t]+'"$QUOTE"'\*/secrets'"$QUOTE"'[ \t]+-prune)'"$QUOTE"'([ \t;&|)]|$)'

# Rendered configs under the data directory carry secrets inline (Authelia's
# configuration.yml, Backrest's config.json), with no extension to exclude.
DATA_PATHS='(^|[ \t'"'"'"=])(\./)?data/|/mnt/|DATA_LOCATION|/var/lib/docker/'

# git grep searches tracked files only, and every secret here is gitignored, so
# it is renamed out of the way rather than matched as a reader. The tokens in
# between exclude command separators: `git status; grep -r ...` must still be
# seen as a grep.
without_git_grep() {
    sed -E 's/(^|[^[:alnum:]_-])git([[:space:]]+[^[:space:];&|()]+)*[[:space:]]+grep/\1git-grep/g'
}

# The exclusions themselves spell `*.env` and `*/secrets/*`, which the SECRETS
# test would otherwise take for the very reads they prevent.
strip_exclusions() {
    sed -E "s#$ENV_EXCLUDED# #g; s#$SECRET_DIRS_EXCLUDED# #g"
}

if printf '%s\n' "$cmd" | without_git_grep | grep -qE "$RECURSIVE_READERS"; then
    if printf '%s' "$cmd" | grep -qE "$DATA_PATHS"; then
        deny 'A recursive read over the data directory reaches rendered configs that carry secrets inline. Name the files, or use git grep for tracked files.'
    fi
    if ! { printf '%s' "$cmd" | grep -qE "$ENV_EXCLUDED" \
        && printf '%s' "$cmd" | grep -qE "$SECRET_DIRS_EXCLUDED"; }; then
        deny "A recursive reader walks into .env files and secrets/ directories that no path in the command names. Exclude both (grep --exclude='*.env' --exclude-dir=secrets; rg -g '!*.env' -g '!secrets'; find ! -name '*.env' ! -path '*/secrets/*'), or use git grep for tracked files."
    fi
fi

if printf '%s' "$cmd" | grep -qE "$READERS" \
    && printf '%s\n' "$cmd" | strip_doc_paths | strip_exclusions | grep -qE "$SECRETS"; then
    deny 'This command reads a file that holds real secrets.'
fi

exit 0
