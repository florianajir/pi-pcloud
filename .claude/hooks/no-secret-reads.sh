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

DENY_HINT='Read key NAMES only (jq -r "keys[]" FILE, grep -oE "^[A-Za-z_][A-Za-z0-9_]*=" FILE),
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

TAB="$(printf '\t')"

# One line per simple command, as "<pipeline number> TAB <command>", split on
# newlines, ;, &&, ||, a lone & and |. A check that needs two things in the same
# command - a recursive grep and its exclusions, `config` and its --quiet - has
# to look at one of these lines, or an `echo` beside the command satisfies it.
# Quotes are not parsed, so a separator inside a quoted string splits too: that
# only ever makes a check stricter. The & of a redirection (2>&1, &>) is kept.
split_commands() {
    awk '
        { text = text (NR > 1 ? "\n" : "") $0 }
        END {
            gsub(/>&/, ">\035", text)
            gsub(/&>/, "\035>", text)
            gsub(/<&/, "<\035", text)
            gsub(/&&|\|\||[;&\n]/, "\034", text)
            n = split(text, pipelines, "\034")
            for (i = 1; i <= n; i++) {
                m = split(pipelines[i], commands, "|")
                for (j = 1; j <= m; j++) {
                    c = commands[j]
                    gsub(/\035/, "\\&", c)
                    print i "\t" c
                }
            }
        }
    '
}

# `docker compose config` renders every env_file inline, so its output carries
# ntfy tokens and database passwords. --quiet validates without printing.
# `config` counts only as the subcommand, right after the global options, so a
# `docker compose exec postgres psql -c '... FROM config'` is not one.
#
# [[:blank:]] rather than the [ \t] used elsewhere in this file: GNU grep took
# the \t of the negated [^ \t] as a backslash and a `t`, so [^ \t]* stopped at
# the t of /tmp and missed `-f /tmp/override.yaml config`.
COMPOSE_CONFIG='docker(-| )compose([[:blank:]]+-[^[:blank:]]+([[:blank:]]+[^-[:blank:]][^[:blank:]]*)?)*[[:blank:]]+config([[:blank:]]|$)'
COMPOSE_QUIET='[[:blank:]]config([[:blank:]]+[^[:blank:]]+)*[[:blank:]]+(--quiet|-q)([[:blank:]]|$)'
if printf '%s\n' "$cmd" | split_commands | cut -f2- \
    | grep -E "$COMPOSE_CONFIG" | grep -qvE "$COMPOSE_QUIET"; then
    deny '`docker compose config` inlines every env_file (passwords, tokens) into its output.'
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
RECURSIVE_READER="$READER_LEAD"'((grep|egrep|fgrep)([ \t]+[^;&|]*)?[ \t]+(-[A-Za-z0-9]*[rR][A-Za-z0-9]*|--recursive|--dereference-recursive|--directories=recurse|-d[ \t]*recurse)([ \t]|$)|rg([ \t]|$)|find[ \t][^;&|]*[ \t]-(exec|execdir|ok|okdir)[ \t]+([^;&|]*[ \t'"'"'"])?'"$READER_WORDS"'([ \t]|$))'
XARGS_READER="$READER_LEAD"'xargs([ \t]+[^;&|]*)?[ \t]+'"$READER_WORDS"'([ \t]|$)'
FIND="$READER_LEAD"'find[ \t]'

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

excludes_secrets() {
    printf '%s' "$1" | grep -qE "$ENV_EXCLUDED" \
        && printf '%s' "$1" | grep -qE "$SECRET_DIRS_EXCLUDED"
}

# A trailing comment would otherwise carry the exclusions for the command it
# follows, without excluding anything.
without_comment() {
    sed -E 's/(^|[[:space:]])#.*$/\1/'
}

# Prints `walks` for each command that reads a tree, and `unexcluded` when that
# command's own words do not exclude both. In `find | xargs grep` the find is
# what chooses the files, so the exclusions belong to it.
recursive_reads() {
    previous=""
    previous_pipeline=""
    printf '%s\n' "$cmd" | without_git_grep | split_commands \
        | while IFS="$TAB" read -r pipeline line; do
            line="$(printf '%s\n' "$line" | without_comment)"
            walker=""
            if printf '%s' "$line" | grep -qE "$RECURSIVE_READER"; then
                walker="$line"
            elif [ "$pipeline" = "$previous_pipeline" ] \
                && printf '%s' "$line" | grep -qE "$XARGS_READER" \
                && printf '%s' "$previous" | grep -qE "$FIND"; then
                walker="$previous"
            fi
            if [ -n "$walker" ]; then
                echo walks
                excludes_secrets "$walker" || echo unexcluded
            fi
            previous="$line"
            previous_pipeline="$pipeline"
        done
}

recursive="$(recursive_reads)"
if [ -n "$recursive" ]; then
    if printf '%s' "$cmd" | grep -qE "$DATA_PATHS"; then
        deny 'A recursive read over the data directory reaches rendered configs that carry secrets inline. Name the files, or use git grep for tracked files.'
    fi
    case "$recursive" in
        *unexcluded*)
            deny "A recursive reader walks into .env files and secrets/ directories that no path in the command names. Exclude both in that same command (grep --exclude='*.env' --exclude-dir=secrets; rg -g '!*.env' -g '!secrets'; find ! -name '*.env' ! -path '*/secrets/*'), or use git grep for tracked files."
            ;;
    esac
fi

# Key names are what the deny message recommends reading, so a command that
# prints nothing else leaves the test below: grep -o with an anchored NAME=
# pattern, or jq's keys. Its operands must be plain words - a $(cat .env) there
# runs a reader whose output grep then echoes back in its "No such file" errors.
KEY_NAME_PATTERN="$QUOTE"'\^\[A-Za-z_\](\+|\[A-Za-z0-9_\]\*)='"$QUOTE"
KEY_NAMES_ONLY='^[[:blank:]]*(grep[[:blank:]]+(-oE|-Eo|-o[[:blank:]]+-E|-E[[:blank:]]+-o)[[:blank:]]+'"$KEY_NAME_PATTERN"'|jq[[:blank:]]+(-r[[:blank:]]+)?'"$QUOTE"'keys(\[\])?'"$QUOTE"')([[:blank:]]+[^-[:blank:]$`()<][^[:blank:]$`()<]*)+[[:blank:]]*$'
secret_scope="$(printf '%s\n' "$cmd" | split_commands | cut -f2- | grep -vE "$KEY_NAMES_ONLY" || true)"

if printf '%s' "$secret_scope" | grep -qE "$READERS" \
    && printf '%s\n' "$secret_scope" | strip_doc_paths | strip_exclusions | grep -qE "$SECRETS"; then
    deny 'This command reads a file that holds real secrets.'
fi

exit 0
