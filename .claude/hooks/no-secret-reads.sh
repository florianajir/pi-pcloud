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
# no control, so a missing jq, an unreadable payload or a crash of this script
# denies rather than waves the command through. Claude Code lets the call
# proceed on any exit other than 2 that prints no decision, and on a timeout -
# hence the EXIT trap, `matches` below, and the single split that keeps a long
# command well inside the 10 s budget.

set -eu

DENY_HINT='Read key NAMES only (jq -r "keys[]" FILE, grep -oE "^[A-Za-z_][A-Za-z0-9_]*=" FILE),
add --quiet to `docker compose config`, redact with sed before printing, or ask
the user to paste the value they want you to see.'

decided=0

# permissionDecision=deny is what actually blocks the call; the reason is shown
# to the model. jq -Rs does the JSON string escaping, so the message may contain
# quotes and newlines.
deny() {
    reason="$1 $DENY_HINT"
    decided=1
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
        "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
}

# Exit 2 is the one status Claude Code treats as a block without JSON, so an
# unexpected failure under set -e ends here instead of in a silent pass.
refuse_on_crash() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$decided" -eq 0 ]; then
        echo "no-secret-reads.sh failed (status $status), so this command was not vetted for secret exposure." >&2
        exit 2
    fi
}
trap refuse_on_crash EXIT

# grep -E's verdict on TEXT. In an `if`, a grep that fails (status 2, or 127
# when it is missing) would read as "no match" and let the command through, so
# that ends the hook instead, through the trap above.
matches() {
    status=0
    printf '%s\n' "$1" | grep -qE "$2" || status=$?
    [ "$status" -le 1 ] || exit 3
    [ "$status" -eq 0 ]
}

# The lines of TEXT that match, or that do not; same contract.
select_lines() {
    status=0
    printf '%s\n' "$1" | grep -E "$2" || status=$?
    [ "$status" -le 1 ] || exit 3
    return 0
}
reject_lines() {
    status=0
    printf '%s\n' "$1" | grep -vE "$2" || status=$?
    [ "$status" -le 1 ] || exit 3
    return 0
}

command -v jq >/dev/null 2>&1 || deny 'Cannot vet this command for secret exposure: jq is unavailable.'

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')" \
    || deny 'Cannot vet this command for secret exposure: the hook payload is not valid JSON.'

[ -n "$cmd" ] || exit 0

# Match against what the shell will EXECUTE, not against data that merely rides
# along in the same string. A heredoc body is stdin for the receiving command,
# so a commit message or a doc paragraph about secret handling is text, not a
# read - and without this the hook blocks its own commit, which is how the need
# for this was discovered.
#
# The exceptions are a heredoc fed to something that executes it - a shell or an
# interpreter given the heredoc (`sh <<EOF`, `python3 - <<'PY'`, which opens
# .env as easily as cat does), one piped into it, `ssh host <<EOF`, and
# `xargs cat <<EOF`, whose body names files - and a heredoc that never closes:
# `<<` inside a quoted string is not one, and skipping to a marker that never
# comes would hide every command after it. Those lines stay in scope. Only the
# word right before `<<` counts, so a PR title mentioning python does not pull
# a `--body "$(cat <<'EOF' ...)"` into scope. A `<<-` marker may be indented
# with tabs. The body is held in an array: appending to one string is quadratic,
# and a 28k-line heredoc used to run past the hook's timeout.
strip_heredoc_bodies() {
    awk '
        BEGIN {
            interpreter = "(sh|bash|zsh|dash|ksh|python[0-9.]*|node|php|perl|ruby)"
            executes = "(^|[[:blank:];&|(\"'"'"'/])(" interpreter "([[:blank:]]+-[^[:blank:]<]*)*|(ssh|xargs)[^<]*)[[:blank:]]*<<"
            piped = "\\|[[:blank:]]*(sudo[[:blank:]]+)?" interpreter "([[:blank:]]|$)"
        }
        skip {
            line = $0
            if (tabbed) { sub(/^\t+/, "", line) }
            if (line == marker) { skip = 0; held = 0 } else { body_lines[++held] = $0 }
            next
        }
        {
            print
            line = $0
            if (line ~ /<<-?[[:blank:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/ \
                && line !~ executes && line !~ piped) {
                tabbed = (line ~ /<<-/)
                marker = line
                sub(/^.*<<-?[[:blank:]]*/, "", marker)
                gsub(/['"'"'"]/, "", marker)
                sub(/[[:blank:]].*$/, "", marker)
                if (marker != "") { skip = 1; held = 0 }
            }
        }
        END { if (skip) { for (i = 1; i <= held; i++) print body_lines[i] } }
    '
}

cmd="$(printf '%s\n' "$cmd" | strip_heredoc_bodies)"
[ -n "$cmd" ] || exit 0

# Leading context for a command word. The quotes matter: the leak that prompted
# this hook was `docker exec pi-kavita sh -c 'cat /config/appsettings.json'`,
# where the reader is preceded by a single quote rather than whitespace, so
# without them every `sh -c '...'` wrapper walks straight through. So do the
# slash of `/bin/cat` and the backslash of `\cat`. Defined here because the
# checks below all need it. The '"'"' is the shell dance for a literal single
# quote.
#
# Every bracket here says [[:blank:]], never [ \t]: GNU grep does not read the
# \t of a bracket consistently. [^ \t]* stopped at the t of /tmp, and [ \t]
# missed a real tab, so a tab-indented `cat .env` in a `sh <<-EOF` body went
# unseen.
READER_LEAD='(^|[[:blank:];&|(`$'"'"'"/\\])'

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

# A trailing comment would otherwise carry the words a check looks for - an
# --exclude, a --quiet, a --format - without them doing anything.
without_comment() {
    sed -E 's/(^|[[:space:]])#.*$/\1/'
}

commands="$(printf '%s\n' "$cmd" | split_commands)"
[ -n "$commands" ] || deny 'Cannot vet this command for secret exposure: it could not be split into commands.'
command_texts="$(printf '%s\n' "$commands" | cut -f2-)"
command_code="$(printf '%s\n' "$command_texts" | without_comment)"

# `docker compose config` renders every env_file inline, so its output carries
# ntfy tokens and database passwords. --quiet validates without printing, and
# the listing flags print names only. `config` counts only as the subcommand,
# right after the global options, so a
# `docker compose exec postgres psql -c '... FROM config'` is not one.
COMPOSE_CONFIG='docker(-| )compose([[:blank:]]+-[^[:blank:]]+([[:blank:]]+[^-[:blank:]][^[:blank:]]*)?)*[[:blank:]]+config([[:blank:]]|$)'
COMPOSE_QUIET='[[:blank:]]config([[:blank:]]+[^[:blank:]]+)*[[:blank:]]+(--quiet|-q|--services|--profiles|--volumes|--images|--networks)([[:blank:]]|$)'
compose_renders="$(select_lines "$command_code" "$COMPOSE_CONFIG")"
compose_prints="$(reject_lines "$compose_renders" "$COMPOSE_QUIET")"
if [ -n "$compose_renders" ] && [ -n "$compose_prints" ]; then
    deny '`docker compose config` inlines every env_file (passwords, tokens) into its output.'
fi

# A container's full environment is where entrypoint-exported secrets live, and
# a --format that prints .Config, or the document itself, prints it too.
INSPECT_ENV='docker[[:blank:]]+inspect[^;&|]*(Config\.Env|\.Env[}] |\{\{[^}]*(\.Config|json[[:blank:]]+\.)[[:blank:]]*\}\}|\{\{[[:blank:]]*\.[[:blank:]]*\}\})'
if matches "$cmd" "$INSPECT_ENV"; then
    deny 'docker inspect .Config.Env prints the container environment, secrets included.'
fi

# A bare `docker inspect` prints the whole container document, Config.Env and
# all. --format picks fields, and so does a jq filter in the next command of
# the pipeline, as long as it names a field, is not the whole of .Config, and is
# not Env. A jq filter's own | splits it, so its pieces are joined back while
# its single quotes are unbalanced.
DOCKER_INSPECT="$READER_LEAD"'docker[[:blank:]]+(container[[:blank:]]+)?inspect([[:blank:]]|$)'
INSPECT_FORMAT='[[:blank:]](--format|-f)([=[:blank:]]|$)'
JQ_FIELD='^[[:blank:]]*jq[[:blank:]].*\.[A-Za-z]'
JQ_WHOLE_CONFIG='Env|\.Config([^.A-Za-z]|$)'

# The patterns reach awk through the environment, not -v, which would process
# the backslash of \. as an escape. Exit 0 means a dump, 1 none.
inspect_dumps() {
    matches "$commands" "$DOCKER_INSPECT" || return 1
    status=0
    printf '%s\n' "$commands" | without_comment \
        | INSPECT="$DOCKER_INSPECT" FORMAT="$INSPECT_FORMAT" JQ_FIELD="$JQ_FIELD" JQ_WHOLE="$JQ_WHOLE_CONFIG" \
            awk -F "$TAB" '
            {
                n++
                pipeline[n] = $1
                text[n] = $0
                sub(/^[^\t]*\t/, "", text[n])
            }
            END {
                for (i = 1; i <= n; i++) {
                    if (text[i] !~ ENVIRON["INSPECT"] || text[i] ~ ENVIRON["FORMAT"]) continue
                    j = i + 1
                    if (j > n || pipeline[j] != pipeline[i]) exit 0
                    filter = text[j]
                    while (gsub(/'"'"'/, "&", filter) % 2 == 1 && j < n && pipeline[j + 1] == pipeline[i]) {
                        j++
                        filter = filter "|" text[j]
                    }
                    if (filter !~ ENVIRON["JQ_FIELD"] || filter ~ ENVIRON["JQ_WHOLE"]) exit 0
                }
                exit 1
            }
        ' || status=$?
    [ "$status" -le 1 ] || exit 3
    [ "$status" -eq 0 ]
}
if inspect_dumps; then
    deny 'A bare docker inspect prints the whole container document, Config.Env included. Add --format with the fields you need, or pipe it to jq naming them.'
fi

# The environment itself: a bare env/printenv, wherever it sits in the line, and
# a single variable whose name says it is a credential - printed by printenv or
# echoed. DATABASE_URL carries ${PASSWORD} for several services here.
ENV_DUMP="$READER_LEAD"'(printenv|env)([[:blank:]]+[0-9]*>[^[:blank:]]*)*[[:blank:]]*([)"'"'"'`]|$)'
SECRET_NAME='[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY|APIKEY|DATABASE_URL)'
SECRET_VARIABLE="$READER_LEAD"'(printenv([[:blank:]]+[A-Za-z0-9_]+)*[[:blank:]]+'"$SECRET_NAME"'|echo[^;&|]*\$\{?'"$SECRET_NAME"')'
if matches "$command_code" "$ENV_DUMP"; then
    deny 'A bare printenv/env dumps the whole environment. Name the one variable you need instead.'
fi
if matches "$command_code" "$SECRET_VARIABLE"; then
    deny 'This prints a variable whose name says it holds a credential. Test that it is set ([ -n "$VAR" ]) or print its length instead.'
fi

# Commands that print a stored secret with no file path for the checks below to
# see. occ config:*:get is how the Redis password leaked; config:list --private
# prints every one of them; redis/valkey CONFIG GET of a password, and ACL LIST,
# print the server's own.
lowered="$(printf '%s\n' "$cmd" | tr '[:upper:]' '[:lower:]')"
if matches "$lowered" 'occ[[:blank:]]+config:(system|app):get[[:blank:]]+[^;&|]*(redis|password|secret|token|dbpassword|apikey|api_key|smtppassword|s3\.[a-z_]*key)|occ[[:blank:]]+config:list[^;&|]*--private'; then
    deny 'occ config:*:get and config:list --private print the raw stored values - this one looks secret-shaped.'
fi
if matches "$lowered" '(redis|valkey)-cli[^;&|]*[[:blank:]](config[[:blank:]]+get[[:blank:]]+[^;&|]*(pass|auth|\*)|acl[[:blank:]]+(list|getuser))'; then
    deny 'This prints the Redis/Valkey password from the server itself.'
fi

# Anything that prints file content. sed/awk/grep/jq are in here deliberately:
# a targeted extraction is exactly how the Kavita TokenKey leaked - the redaction
# keyed on the wrong field name, matched nothing, and printed the file whole.
# So are the line tools: `diff .env .env.dist` prints every value that differs.
READER_WORDS='(cat|batcat|bat|tac|nl|less|more|head|tail|strings|xxd|od|hexdump|base64|sed|awk|gawk|mawk|grep|egrep|fgrep|zgrep|rg|jq|yq|dd|tee|cut|sort|uniq|diff|sdiff|comm|join|paste|column|fold|rev|tr|zcat|sqlite3|php|node|perl|ruby|python[0-9.]*)'
READERS="$READER_LEAD$READER_WORDS"'([[:blank:]]|$)'

# Paths that hold real secrets. The `.template` and `.dist` forms are
# deliberately NOT matched - they carry placeholders, and reading them is how
# the rendering scripts get understood. The `.env` backups and leftovers
# (.env.bak.<date>, n8n.env.bak.*) hold the same values as the file itself; a
# fixed suffix list, so `process.env.HOME` in a node one-liner stays readable.
# The rest are the stack's gitignored renders and their in-container paths:
# Backrest's restic password and S3 keys, Headscale's OIDC secret, Headplane's
# cookie secret and API key, the VPN profile, Forgejo's app.ini, LLDAP's config,
# the *arr and qBittorrent configs with their API keys, changedetection's
# watches, Traefik's ACME private keys, and a process environment.
#
# A path ends at a blank, a quote, a separator, a redirection, a backtick, or a
# glob or brace character - `.env*` and `.env{.dist,}` expand to .env. A name
# that is only a fragment elsewhere starts at a path boundary: jq's `.key`,
# `custom.config.php` and the word "credentials" in a compose file are not
# secrets.
END_OF_PATH='([[:blank:]"'"'"';&|)<>`*?{},]|$)'
NAME_START='(^|[/[:blank:]"'"'"'=:{,])'
SECRETS='(\.env(\.(bak|tmp|old|orig|save|local|prod)[A-Za-z0-9_.-]*)?'"$END_OF_PATH"'|authelia-config/secrets|homepage/secrets|/config/secrets/|appsettings\.json|immich-oauth-config|configuration\.yml'"$END_OF_PATH"'|'"$NAME_START"'config\.php'"$END_OF_PATH"'|oidc_[a-z-]+_secret|_secret\.txt|/secrets/|[A-Za-z0-9_-]\.pem'"$END_OF_PATH"'|[A-Za-z0-9_-]\.key'"$END_OF_PATH"'|id_(rsa|ed25519|ecdsa|dsa)'"$END_OF_PATH"'|(/|\.git-)credentials(\.[a-z]+)?'"$END_OF_PATH"'|backrest/config\.json(\.bak[A-Za-z0-9_.-]*)?'"$END_OF_PATH"'|head(scale|plane)/config\.yaml'"$END_OF_PATH"'|headscale_api_key'"$END_OF_PATH"'|\.ovpn'"$END_OF_PATH"'|'"$NAME_START"'\.rotate-password\.|app\.ini'"$END_OF_PATH"'|lldap_config\.toml'"$END_OF_PATH"'|acme\.json'"$END_OF_PATH"'|config\.xml'"$END_OF_PATH"'|qBittorrent\.conf'"$END_OF_PATH"'|url-watches\.json'"$END_OF_PATH"'|/proc/[^/[:blank:]]+/environ)'

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
# keys with no extension at all.
#
# Even both exclusions are not enough over the repository root or its config/
# tree, which also hold the gitignored renders above (Backrest's config.json,
# Headscale's and Headplane's config.yaml): a walk there is refused outright,
# since git grep searches exactly the tracked, secret-free files. So is a walk
# that names a secrets/ directory as its operand - GNU grep does not apply
# --exclude-dir to one. A walk restricted to source files (--include='*.sh',
# -name '*.py', -g '*.md') reads none of this, and passes anywhere.
RECURSIVE_READER="$READER_LEAD"'((grep|egrep|fgrep|zgrep)([[:blank:]]+[^;&|]*)?[[:blank:]]+(-[A-Za-z0-9]*[rR][A-Za-z0-9]*|--recursive|--dereference-recursive|--directories=recurse|-d[[:blank:]]*recurse)([[:blank:]]|$)|rg([[:blank:]]|$)|find[[:blank:]][^;&|]*[[:blank:]]-(exec|execdir|ok|okdir)[[:blank:]]+([^;&|]*[[:blank:]'"'"'"/])?'"$READER_WORDS"'([[:blank:]]|$))'
XARGS_READER="$READER_LEAD"'xargs([[:blank:]]+[^;&|]*)?[[:blank:]]+([^;&|]*/)?'"$READER_WORDS"'([[:blank:]]|$)'
FIND="$READER_LEAD"'find[[:blank:]]'

QUOTE='['"'"'"]?'
ENV_EXCLUDED='(--exclude(=|[[:blank:]]+)'"$QUOTE"'|(-g|--glob|--iglob)(=|[[:blank:]]+)'"$QUOTE"'!|(!|\\!|-not)[[:blank:]]+-i?name[[:blank:]]+'"$QUOTE"')\\?\*\.env'"$QUOTE"'([[:blank:];&|)]|$)'
SECRET_DIRS_EXCLUDED='(--exclude-dir(=|[[:blank:]]+)'"$QUOTE"'secrets|(-g|--glob|--iglob)(=|[[:blank:]]+)'"$QUOTE"'!(\*\*/)?secrets(/\*\*)?/?|(!|\\!|-not)[[:blank:]]+-path[[:blank:]]+'"$QUOTE"'\*/secrets(/\*)?|-path[[:blank:]]+'"$QUOTE"'\*/secrets'"$QUOTE"'[[:blank:]]+-prune)'"$QUOTE"'([[:blank:];&|)]|$)'
SOURCE_ONLY='(--include(=|[[:blank:]]+)|(-g|--glob|--iglob)(=|[[:blank:]]+)|-i?name[[:blank:]]+)'"$QUOTE"'\*\.(sh|py|md|markdown|template|dist|js|ts|html|css)'"$QUOTE"'([[:blank:]]|$)'
OPERAND_END='([[:blank:]'"'"'"]|$)'
REPO_TREE='(^|[[:blank:]'"'"'"=])(\.|\./|\.\./?|(\./)?config(/[^[:blank:]'"'"'"]*)?|[^[:blank:]'"'"'"]*/pi-web(/config(/[^[:blank:]'"'"'"]*)?)?/?)'"$OPERAND_END"
SECRETS_DIR_OPERAND='(^|[[:blank:]'"'"'"=/])secrets/?'"$OPERAND_END"

# Rendered configs under the data directory carry secrets inline (Authelia's
# configuration.yml, the agentgateway database with its provider keys), with
# no extension to exclude, and so do the containers' own /data and /userdata
# mounts. A tree walk refuses any mention of the directory; a single read
# refuses a path into it - the bare word DATA_LOCATION is a search pattern, not
# a file, when it is not followed by a /.
DATA_PATHS='(^|[[:blank:]'"'"'"=])(\./)?data/|/mnt/|DATA_LOCATION|/var/lib/docker/'
DATA_FILES='(^|[[:blank:]'"'"'"=:])(\./)?data/|/data/|/userdata/|/mnt/|\$\{?DATA_LOCATION[^/[:blank:]]*/|/var/lib/docker/'

# git grep searches tracked files only, and every secret here is gitignored, so
# it is renamed out of the way rather than matched as a reader. Only git's own
# global options may stand between the two words: `docker exec -u git
# pi-forgejo grep` runs grep as the git user, and that user is renamed first.
# With --no-index or --no-exclude-standard git grep searches the ignored files
# too, so it is renamed into the recursive grep it then is.
GIT_GLOBAL_OPTIONS='([[:space:]]+(-C|-c)[[:space:]]+[^[:space:];&|()]+|[[:space:]]+--?[A-Za-z][^[:space:];&|()]*)*'
without_git_grep() {
    sed -E 's/(-u|--user)([[:blank:]]+|=)git([[:blank:]])/\1\2_git_\3/g
            /--no-index|--no-exclude-standard/s/(^|[^[:alnum:]_-])git'"$GIT_GLOBAL_OPTIONS"'[[:space:]]+grep/\1grep -r/g
            s/(^|[^[:alnum:]_-])git'"$GIT_GLOBAL_OPTIONS"'[[:space:]]+grep/\1git-grep/g'
}

# The exclusions themselves spell `*.env` and `*/secrets/*`, which the SECRETS
# test would otherwise take for the very reads they prevent.
strip_exclusions() {
    sed -E "s#$ENV_EXCLUDED# #g; s#$SECRET_DIRS_EXCLUDED# #g"
}

excludes_secrets() {
    matches "$1" "$ENV_EXCLUDED" && matches "$1" "$SECRET_DIRS_EXCLUDED"
}

# Prints `walks` for a command that reads a tree, then `tree` if it starts from
# the repository or config/ or names a secrets/ directory, or `unexcluded` if
# its own words do not exclude both.
walk_verdict() {
    echo walks
    if matches "$1" "$SOURCE_ONLY"; then
        return 0
    fi
    operands="$(printf '%s\n' "$1" | strip_exclusions)"
    if matches "$operands" "$REPO_TREE" || matches "$operands" "$SECRETS_DIR_OPERAND"; then
        echo tree
    elif ! excludes_secrets "$1"; then
        echo unexcluded
    fi
}

# In `find | ... | xargs grep` the find is what chooses the files, so its words
# decide - however many filters sit between the two. The loop only runs when
# one grep over all the commands found a candidate, and not past 50 of them: it
# costs a few processes per command - 200 took 3.5 s on the Pi - and a timed-out
# hook lets the command through.
MAX_TREE_WALKS=50
recursive_reads() {
    walkable="$(printf '%s\n' "$commands" | without_git_grep | without_comment)"
    candidates="$(select_lines "$walkable" "$RECURSIVE_READER|$XARGS_READER")"
    [ -n "$candidates" ] || return 0
    if [ "$(printf '%s\n' "$candidates" | wc -l)" -gt "$MAX_TREE_WALKS" ]; then
        echo too-many
        return 0
    fi
    last_find=""
    find_pipeline=""
    printf '%s\n' "$walkable" | while IFS="$TAB" read -r pipeline line; do
        [ "$pipeline" = "$find_pipeline" ] || last_find=""
        walker=""
        if matches "$line" "$RECURSIVE_READER"; then
            walker="$line"
        elif [ -n "$last_find" ] && matches "$line" "$XARGS_READER"; then
            walker="$last_find"
        fi
        if matches "$line" "$FIND"; then
            last_find="$line"
            find_pipeline="$pipeline"
        fi
        [ -z "$walker" ] || walk_verdict "$walker"
    done
}

recursive="$(recursive_reads)"
if [ -n "$recursive" ]; then
    if matches "$cmd" "$DATA_PATHS"; then
        deny 'A recursive read over the data directory reaches rendered configs that carry secrets inline. Name the files, or use git grep for tracked files.'
    fi
    case "$recursive" in
        *too-many*)
            deny "This command holds more than $MAX_TREE_WALKS recursive reads, more than the hook can vet inside its timeout. Split it."
            ;;
        *tree*)
            deny "A recursive read of the repository or its config/ tree reaches gitignored renders that hold secrets (Backrest's config.json, Headscale's and Headplane's config.yaml) whatever it excludes, and a secrets/ operand is read whatever --exclude-dir says. Use git grep, which searches tracked files only, or restrict the walk to source files (--include='*.sh')."
            ;;
        *unexcluded*)
            deny "A recursive reader walks into .env files and secrets/ directories that no path in the command names. Exclude both in that same command (grep --exclude='*.env' --exclude-dir=secrets; rg -g '!*.env' -g '!secrets'; find ! -name '*.env' ! -path '*/secrets/*'), or use git grep for tracked files."
            ;;
    esac
fi

# Key names are what the deny message recommends reading, so a command that
# prints nothing else leaves the test below: grep -o with an anchored NAME=
# pattern, or jq's keys. Its operands must be plain words - a $(cat .env) there
# runs a reader whose output grep then echoes back in its "No such file" errors.
# And `cat <<EOF` reads its heredoc, not a file: it is how a PR body is passed,
# and a title that mentions .env must not make it a read.
KEY_NAME_PATTERN="$QUOTE"'\^\[A-Za-z_\](\+|\[A-Za-z0-9_\]\*)='"$QUOTE"
KEY_NAMES_ONLY='^[[:blank:]]*(grep[[:blank:]]+(-oE|-Eo|-o[[:blank:]]+-E|-E[[:blank:]]+-o)[[:blank:]]+'"$KEY_NAME_PATTERN"'|jq[[:blank:]]+(-r[[:blank:]]+)?'"$QUOTE"'keys(\[\])?'"$QUOTE"')([[:blank:]]+[^-[:blank:]$`()<][^[:blank:]$`()<]*)+[[:blank:]]*$'
not_key_names="$(reject_lines "$command_texts" "$KEY_NAMES_ONLY")"
secret_scope="$(printf '%s\n' "$not_key_names" | without_git_grep \
    | sed -E '/xargs/!s/(^|[^[:alnum:]_-])cat[[:blank:]]*<</\1heredoc<</g')"

if matches "$secret_scope" "$READERS"; then
    if matches "$(printf '%s\n' "$secret_scope" | strip_doc_paths | strip_exclusions)" "$SECRETS"; then
        deny 'This command reads a file that holds real secrets. To search tracked files for that name, use git grep.'
    fi
    if matches "$(printf '%s\n' "$secret_scope" | strip_doc_paths)" "$DATA_FILES"; then
        deny 'This command reads under a data directory, where rendered configs and databases carry secrets inline. Ask for the value, or use git grep to search tracked files for a path.'
    fi
fi

exit 0
