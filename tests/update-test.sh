#!/bin/sh
# Tests for scripts/update.sh, the sequence behind `make update` and
# `make update-images`: what runs, in which order, and what a failure says.
#
# Each case runs the real script and lib.sh in a fresh clone that is one commit
# behind a throwaway origin, so `git pull` really moves HEAD. docker, systemctl,
# sudo and sleep are stubs on PATH, and check-env.sh, changed-services.sh,
# stack-up.sh and install-system.sh are stubs in the clone, all recording their
# calls - so no container, no unit and no host file is touched. Run with
# `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

contains() {
    case "$2" in
        *"$3"*) ok "$1" yes yes ;;
        *) ok "$1" "$2" "(contains) $3" ;;
    esac
}

lacks() {
    case "$2" in
        *"$3"*) ok "$1" "$2" "(lacks) $3" ;;
        *) ok "$1" yes yes ;;
    esac
}

CALLS="$WORK/calls"
PULLS="$WORK/pulls"
export CALLS PULLS

# --- stubs on PATH ------------------------------------------------------------

mkdir -p "$WORK/bin"

cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$CALLS"
case "$*" in
    "compose pull --ignore-buildable")
        n=$(($(cat "$PULLS" 2>/dev/null || echo 0) + 1))
        echo "$n" >"$PULLS"
        [ "$n" -gt "${FAIL_PULLS:-0}" ] ;;
    "compose build --pull") [ -z "${FAIL_BUILD:-}" ] ;;
    *--force-recreate*) [ -z "${FAIL_RECREATE:-}" ] ;;
    *--wait*) [ -z "${FAIL_WAIT:-}" ] ;;
    "image prune -f") echo "Total reclaimed space: 0B" ;;
esac
STUB

cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >>"$CALLS"
case "$1" in
    is-active) [ -n "${UNIT_ACTIVE:-}" ] ;;
esac
STUB

cat >"$WORK/bin/sleep" <<'STUB'
#!/bin/sh
echo "sleep $*" >>"$CALLS"
STUB

cat >"$WORK/bin/sudo" <<'STUB'
#!/bin/sh
exec "$@"
STUB

chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

# --- an origin one commit ahead of every clone --------------------------------

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
# Applies to the clones' `git pull` too: a detached `git maintenance run --auto`
# can still be writing into .git when the EXIT trap removes $WORK.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false

ORIGIN="$WORK/origin"
mkdir -p "$ORIGIN/scripts"
cp "$REPO_DIR/scripts/update.sh" "$REPO_DIR/scripts/lib.sh" "$ORIGIN/scripts/"

cat >"$ORIGIN/scripts/changed-services.sh" <<'STUB'
#!/bin/sh
echo "changed-services.sh $*" >>"$CALLS"
[ -z "${CHANGED_ANSWER:-}" ] || printf '%s\n' $CHANGED_ANSWER
exit "${CHANGED_STATUS:-0}"
STUB
# Logs the commit it runs against, which is how the cases below tell that the
# check runs the pulled script rather than the one before the pull.
cat >"$ORIGIN/scripts/check-env.sh" <<'STUB'
#!/bin/sh
echo "check-env.sh at $(git rev-parse HEAD)" >>"$CALLS"
[ -z "${FAIL_CHECK_ENV:-}" ]
STUB
for stub in stack-up.sh install-system.sh; do
    printf '#!/bin/sh\necho "%s" >>"$CALLS"\n' "$stub" >"$ORIGIN/scripts/$stub"
done

git -C "$ORIGIN" init -q -b main
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit -qm before
BEFORE="$(git -C "$ORIGIN" rev-parse HEAD)"
echo after >"$ORIGIN/upstream-change"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit -qm after
AFTER="$(git -C "$ORIGIN" rev-parse HEAD)"

clones=0
fresh_clone() {
    clones=$((clones + 1))
    APP="$WORK/app$clones"
    git clone -q "$ORIGIN" "$APP"
    git -C "$APP" reset -q --hard "$BEFORE"
}

base_file() {
    printf '%s/%s' "$APP" "$(git -C "$APP" rev-parse --git-path pi-pcloud-update-base)"
}

# Usage: run_update <update.sh argument, or ""> [NAME=value ...]
# Sets $out (stdout and stderr), $rc and $calls.
run_update() {
    local mode="$1"
    shift
    : >"$CALLS"
    rm -f "$PULLS"
    rc=0
    if [ -n "$mode" ]; then
        out="$(cd "$APP" && env "$@" sh scripts/update.sh "$mode" 2>&1)" || rc=$?
    else
        out="$(cd "$APP" && env "$@" sh scripts/update.sh 2>&1)" || rc=$?
    fi
    calls="$(cat "$CALLS")"
}

# --- the full sequence ---------------------------------------------------------

fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_ANSWER="kavita ntfy"
ok "an update with changed config succeeds" "$rc" 0
ok "and runs every step in order" "$calls" "$(cat <<EOF
check-env.sh at $AFTER
docker compose pull --ignore-buildable
docker compose build --pull
install-system.sh
systemctl try-restart pi-pcloud-authelia-ntfy.service
changed-services.sh $BEFORE HEAD
systemctl is-active --quiet pi-pcloud.service
stack-up.sh
docker compose up -d --no-deps --force-recreate kavita ntfy
docker compose up -d --no-deps --wait --wait-timeout 180 kavita ntfy
docker image prune -f
EOF
)"
contains "and says so" "$out" "✅ Update complete"
ok "the checkout moved to the pulled commit" "$(git -C "$APP" rev-parse HEAD)" "$AFTER"

# --- what the pull changed decides the apply ------------------------------------

fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_ANSWER=ALL
contains "an unattributable change restarts the stack" "$calls" "systemctl restart pi-pcloud.service"
lacks "  instead of the in-place apply" "$calls" "stack-up.sh"

fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_STATUS=3
contains "a changed-services failure counts as ALL" "$calls" "systemctl restart pi-pcloud.service"
ok "  and is not an update failure" "$rc" 0

fresh_clone
run_update "" UNIT_ACTIVE=1
contains "nothing to re-read still applies in place" "$calls" "stack-up.sh"
lacks "  and recreates nothing" "$calls" "--force-recreate"

fresh_clone
run_update ""
contains "an inactive unit is started through systemd" "$calls" "systemctl start pi-pcloud.service"
lacks "  rather than by running the start sequence" "$calls" "stack-up.sh"

# --- the two ways a recreate can go wrong ----------------------------------------

fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_ANSWER=kavita FAIL_WAIT=1
ok "a slow healthcheck is not a failed update" "$rc" 0
contains "  but is named" "$out" "not healthy within 180s: kavita"

fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_ANSWER=kavita FAIL_RECREATE=1
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "a container that cannot be created fails the update" "$failed" yes
lacks "  without claiming success" "$out" "✅"
contains "  and says the new version may already run" "$out" "Host files and containers may already run"
contains "  and prints the full way back to the previous commit" "$out" \
    "git reset --hard $BEFORE && make install-system && docker compose build && make restart"
contains "  or to run it again" "$out" "run \`make update\` again: it resumes from"

# --- image pulls -------------------------------------------------------------------

fresh_clone
run_update "" UNIT_ACTIVE=1 FAIL_PULLS=2
ok "a rate-limited pull is retried" "$rc" 0
ok "  after 20 s then 40 s" "$(grep '^sleep' "$CALLS" | tr '\n' ' ')" "sleep 20 sleep 40 "

fresh_clone
run_update "" UNIT_ACTIVE=1 FAIL_PULLS=3
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "a third failed pull stops the update" "$failed" yes
contains "  with the reason" "$out" "Image pull failed after 3 attempts"
lacks "  before the host files are applied" "$calls" "install-system.sh"

# --- a pull that never happened ----------------------------------------------------

fresh_clone
git -C "$APP" remote set-url origin "$WORK/no-such-origin"
run_update "" UNIT_ACTIVE=1
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "a failed git pull fails the update" "$failed" yes
contains "  and says so" "$out" "❌ Update failed."
lacks "  with no way back to print, since nothing moved" "$out" "go back"
ok "  and nothing after it ran" "$calls" ""
ok "  and no start commit recorded for a resume" "$([ -e "$(base_file)" ] && echo recorded)" ""

# --- running it again after a failure ------------------------------------------------
#
# The second run finds the pull already done. Without the recorded start it
# would diff HEAD against HEAD and recreate nothing the first pull changed.

fresh_clone
run_update "" UNIT_ACTIVE=1 FAIL_CHECK_ENV=1
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "a check-env failure after the pull fails the update" "$failed" yes
contains "  says nothing was applied" "$out" "Nothing was applied yet."
contains "  and that running it again resumes" "$out" \
    "run \`make update\` again: it resumes from $(git -C "$APP" rev-parse --short "$BEFORE")"
contains "  with a way back that is only a reset" "$out" "↩ Or go back: git reset --hard $BEFORE"
lacks "  and no restart" "$out" "make restart"
ok "  and records where it started and how far it got" "$(cat "$(base_file)" 2>/dev/null)" "$BEFORE none"

run_update "" UNIT_ACTIVE=1
ok "running it again completes" "$rc" 0
contains "  says it resumes" "$out" "resuming the update that failed"
contains "  and still applies what the first pull changed" "$calls" "changed-services.sh $BEFORE HEAD"
ok "  then forgets the start commit" "$([ -e "$(base_file)" ] && echo recorded)" ""

fresh_clone
run_update "" UNIT_ACTIVE=1 FAIL_BUILD=1
contains "a failed image build says the running stack is untouched" "$out" \
    "Nothing was applied to the running stack"
contains "  and goes back with a rebuild, not a restart" "$out" \
    "↩ Or go back: git reset --hard $BEFORE && docker compose build"
lacks "  without a restart" "$out" "make restart"

# A rerun that fails again before reaching as far as the first one still
# reports what the first one applied.
fresh_clone
run_update "" UNIT_ACTIVE=1 CHANGED_ANSWER=kavita FAIL_RECREATE=1
git -C "$APP" remote set-url origin "$WORK/no-such-origin"
run_update "" UNIT_ACTIVE=1
contains "a rerun whose pull fails keeps the first run's stage" "$out" \
    "Host files and containers may already run"
contains "  and its full way back" "$out" "make install-system && docker compose build && make restart"
ok "  and keeps the record" "$(cat "$(base_file)" 2>/dev/null)" "$BEFORE host"

# A record with no stage (a truncated write) assumes the worst.
fresh_clone
git -C "$APP" pull -q --ff-only
printf '%s\n' "$BEFORE" >"$(base_file)"
run_update "" UNIT_ACTIVE=1 FAIL_CHECK_ENV=1
contains "a record without a stage counts as the worst" "$out" "Host files and containers may already run"

# A start commit that is not behind HEAD any more - the checkout was reset
# further back since - describes nothing here, and is ignored.
fresh_clone
printf '%s\n' "$AFTER" >"$(base_file)"
run_update "" UNIT_ACTIVE=1
ok "a start commit ahead of HEAD is ignored" "$rc" 0
lacks "  with no resume announced" "$out" "resuming"
contains "  and the range taken from HEAD as usual" "$calls" "changed-services.sh $BEFORE HEAD"

# --- images only ---------------------------------------------------------------------

fresh_clone
run_update --images UNIT_ACTIVE=1
ok "an images-only update succeeds" "$rc" 0
ok "  without pulling the repository" "$(git -C "$APP" rev-parse HEAD)" "$BEFORE"
ok "  and runs only the image steps" "$calls" "$(cat <<EOF
check-env.sh at $BEFORE
docker compose pull --ignore-buildable
docker compose build --pull
systemctl is-active --quiet pi-pcloud.service
stack-up.sh
docker image prune -f
EOF
)"
contains "  and says so" "$out" "✅ Images up to date"

# --- usage -------------------------------------------------------------------------

fresh_clone
run_update --bogus
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "an unknown argument is refused" "$failed" yes
ok "  before anything runs" "$calls" ""

printf 'update-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
