#!/bin/sh
# Every static check the CI runs, in one place: the workflow calls this script
# too, so the two cannot drift the way two copies of a rule always do.
#
# A gate whose tool is absent is reported as skipped rather than silently
# dropped, so a contributor gets whatever they have installed. CI sets
# LINT_STRICT=1, which turns a skipped gate into a failure.
#
# hadolint, actionlint and gitleaks have no packaged arm64 build worth
# depending on, so they run from pinned images when the binary is missing.
set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_DIR"

HADOLINT_IMAGE="hadolint/hadolint:v2.14.0"
ACTIONLINT_IMAGE="rhysd/actionlint:1.7.7"
GITLEAKS_IMAGE="zricethezav/gitleaks:v8.28.0"

# A floor, not just a non-empty check: a pathspec that half-breaks (a renamed
# directory, a glob that stops matching config/**) still returns *something*,
# and the gate would pass having checked three files. There are 58 today;
# raise the floor when that count grows well past it, and never lower it to
# make a failure go away.
SHELL_FILE_FLOOR=50

STRICT="${LINT_STRICT:-0}"
failures=0
skips=0

pass() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33m·\033[0m %s\n' "$*"; skips=$((skips + 1)); }
gate() { printf '\n\033[1m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# `docker run` reports a missing image, its layers and the final digest on
# stderr, which the gates below capture together with the tool's own output: on
# a cold runner that turned 3 hadolint findings into a count of 11. Pulling
# first keeps the two streams apart.
docker_lint() {
    image="$1"
    shift
    docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
    docker run --rm -v "$PROJECT_DIR:/repo:ro" -w /repo "$image" "$@"
}

# Listed from git rather than globbed, so config/**/*.sh (the postgres init and
# the nextcloud hooks) and the extensionless scripts/pi-pcloud are covered too.
shell_files() { git ls-files '*.sh' 'scripts/pi-pcloud'; }

shell_file_count() {
    # grep -c exits 1 on no match, which under `set -e` would abort with no
    # message rather than the one the caller prints.
    shell_files | grep -c . || true
}

# dash, not sh: on a developer's machine /bin/sh can be bash, which accepts the
# bashisms the stack forbids. The stack is run by dash.
posix_shell() { if have dash; then echo dash; else echo sh; fi; }

# Dialect from the shebang, like the syntax gate: one file (the postgres init)
# declares bash, and forcing dash on it would report its own shell as an error.
shellcheck_dialect() {
    case "$(head -n1 "$1")" in
        *bash*) echo bash ;;
        *)      echo dash ;;
    esac
}

gate_shell_files() {
    gate "Shell file list"
    count="$(shell_file_count)"
    if [ "$count" -lt "$SHELL_FILE_FLOOR" ]; then
        fail "git ls-files matched only $count shell files, expected at least $SHELL_FILE_FLOOR - broken pathspec?"
        shell_files
        return 0
    fi
    pass "$count files"
}

gate_shell_syntax() {
    gate "Shell syntax"
    sh_bin="$(posix_shell)"
    bad=0
    for file in $(shell_files); do
        case "$(shellcheck_dialect "$file")" in
            bash) bash -n "$file" || bad=1 ;;
            *)    "$sh_bin" -n "$file" || bad=1 ;;
        esac
    done
    [ "$bad" -eq 0 ] && pass "parses ($sh_bin -n / bash -n)" || fail "syntax errors above"
}

# -s dash is the POSIX gate: it reports every bashism as an SC3xxx error, which
# is what checkbashisms is for elsewhere in the docs, except shellcheck parses
# the files correctly instead of choking on nested quotes.
# -x follows `. lib.sh`, so a helper's variables are resolved rather than
# guessed.
gate_shellcheck() {
    gate "shellcheck"
    if ! have shellcheck; then
        skip "shellcheck not installed"
        return 0
    fi
    dash_files=""
    bash_files=""
    for file in $(shell_files); do
        case "$(shellcheck_dialect "$file")" in
            bash) bash_files="$bash_files $file" ;;
            *)    dash_files="$dash_files $file" ;;
        esac
    done
    bad=0
    # shellcheck disable=SC2086 # deliberate word splitting of the file list
    [ -z "$dash_files" ] || shellcheck -s dash -x --severity=warning $dash_files || bad=1
    # shellcheck disable=SC2086
    [ -z "$bash_files" ] || shellcheck -s bash -x --severity=warning $bash_files || bad=1
    [ "$bad" -eq 0 ] && pass "no warnings" || fail "findings above"
}

# Tracked files, not `.`: yamllint has no gitignore awareness, so a bare `.`
# walks into .claude/worktrees/ and lints stale copies of the whole repo.
#
# .yamllint keeps line-length advisory on purpose - a Traefik label or an image
# digest cannot be wrapped - so this gate exits 0 with findings on screen.
# Counting them keeps the verdict honest: "clean" under a wall of warnings is
# how a gate stops being read.
gate_yamllint() {
    gate "yamllint"
    if ! have yamllint; then
        skip "yamllint not installed (see requirements-lint.txt)"
        return 0
    fi
    files="$(git ls-files '*.yaml' '*.yml')"
    if [ -z "$files" ]; then
        fail "no YAML matched - broken pathspec?"
        return 0
    fi
    # shellcheck disable=SC2086 # deliberate word splitting of the file list
    if ! output="$(yamllint -c .yamllint -f parsable $files 2>&1)"; then
        printf '%s\n' "$output"
        fail "errors above"
        return 0
    fi
    advisory="$(printf '%s' "$output" | grep -c . || true)"
    if [ "$advisory" -gt 0 ]; then
        printf '%s\n' "$output"
        pass "no errors ($advisory advisory warning(s) above)"
    else
        pass "clean"
    fi
}

# Tracked files, not `.`: ruff honours .gitignore, but .claude/worktrees/ is
# excluded only by a machine-local .git/info/exclude on one checkout, so `.`
# would lint stale copies of the repo for anyone else.
gate_ruff() {
    gate "ruff"
    if ! have ruff; then
        skip "ruff not installed (see requirements-lint.txt)"
        return 0
    fi
    files="$(git ls-files '*.py')"
    if [ -z "$files" ]; then
        fail "no Python matched - broken pathspec?"
        return 0
    fi
    # shellcheck disable=SC2086 # deliberate word splitting of the file list
    ruff check $files && pass "clean" || fail "findings above"
}

# The secret-exposure hook vets every Bash call an agent makes, and a pattern
# that stops matching lets the command through without a word - so a
# regression in it shows up nowhere but here.
gate_secret_hook() {
    gate "secret-exposure hook"
    if ! have jq; then
        skip "jq not installed"
        return 0
    fi
    sh .claude/hooks/no-secret-reads.test.sh && pass "every case holds" || fail "findings above"
}

# .hadolint.yaml sets failure-threshold: warning, so info-level findings print
# and still exit 0. Counted rather than called clean, for the reason above.
gate_hadolint() {
    gate "hadolint"
    files="$(git ls-files '*Dockerfile' '*Dockerfile.*')"
    if [ -z "$files" ]; then
        fail "no Dockerfile matched - broken pathspec?"
        return 0
    fi
    via=""
    if have hadolint; then
        # shellcheck disable=SC2086 # deliberate word splitting of the file list
        output="$(hadolint --no-color $files 2>&1)" && rc=0 || rc=$?
    elif have docker; then
        via=" (via $HADOLINT_IMAGE)"
        # shellcheck disable=SC2086
        output="$(docker_lint "$HADOLINT_IMAGE" hadolint --no-color $files 2>&1)" && rc=0 || rc=$?
    else
        skip "neither hadolint nor docker available"
        return 0
    fi
    [ -z "$output" ] || printf '%s\n' "$output"
    if [ "$rc" -ne 0 ]; then
        fail "findings at or above the warning threshold above"
        return 0
    fi
    advisory="$(printf '%s' "$output" | grep -c . || true)"
    if [ "$advisory" -gt 0 ]; then
        pass "nothing at the warning threshold$via ($advisory advisory finding(s) above)"
    else
        pass "clean$via"
    fi
}

gate_actionlint() {
    gate "actionlint"
    if have actionlint; then
        actionlint && pass "clean" || fail "findings above"
    elif have docker; then
        docker_lint "$ACTIONLINT_IMAGE" \
            && pass "clean (via $ACTIONLINT_IMAGE)" || fail "findings above"
    else
        skip "neither actionlint nor docker available"
    fi
}

# `gitleaks git`, never a working-tree scan: the tree holds .env and the
# rendered data/ configs, which hold live secrets and must not be read, let
# alone echoed into a terminal or a CI log. History is the surface that
# matters anyway - a secret is only leaked once it is committed.
# --redact so a finding names the file and rule without reprinting the secret.
gate_gitleaks() {
    gate "gitleaks"
    if have gitleaks; then
        gitleaks git --redact --exit-code 1 && pass "no leaks in history" || fail "findings above"
    elif have docker; then
        docker_lint "$GITLEAKS_IMAGE" git --redact --exit-code 1 \
            && pass "no leaks in history (via $GITLEAKS_IMAGE)" || fail "findings above"
    else
        skip "neither gitleaks nor docker available"
    fi
}

gate_shell_files
gate_shell_syntax
gate_shellcheck
gate_yamllint
gate_ruff
gate_secret_hook
gate_hadolint
gate_actionlint
gate_gitleaks

printf '\n'
if [ "$failures" -gt 0 ]; then
    printf '\033[31m%s gate(s) failed\033[0m\n' "$failures"
    exit 1
fi
if [ "$skips" -gt 0 ] && [ "$STRICT" = "1" ]; then
    printf '\033[31m%s gate(s) skipped and LINT_STRICT=1\033[0m\n' "$skips"
    exit 1
fi
if [ "$skips" -gt 0 ]; then
    printf '\033[32mall gates passed\033[0m (%s skipped)\n' "$skips"
else
    printf '\033[32mall gates passed\033[0m\n'
fi
