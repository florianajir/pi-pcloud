#!/bin/sh
# Tests for scripts/check-secrets.sh (`make check-secrets`, and the last block
# of `make doctor`) and scripts/headscale-nodes.sh (`make headscale-register`,
# `make headscale-reset`).
#
# Each runs in a throwaway checkout: rotate-secret.sh is a stub answering a
# fixed set of statuses, and docker and sudo are stubs on PATH that record
# their calls - so no container is touched and no secret is read. Run with
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
export CALLS

mkdir -p "$WORK/bin"

cat >"$WORK/bin/sudo" <<'STUB'
#!/bin/sh
echo "sudo $*" >>"$CALLS"
[ "$1" != "-v" ] || exit "${SUDO_FAILS:-0}"
exec "$@"
STUB

# Answers the two listings headscale-nodes.sh parses, and fails the node
# listing or a node delete when asked to.
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$CALLS"
case "$*" in
    *"headscale nodes list -o json")
        [ -z "${FAIL_LIST:-}" ] || exit 1
        echo '[{"id":1},{"id":2}]'
        ;;
    *"headscale preauthkeys list -o json") echo '[{"id":7}]' ;;
    *"nodes delete --identifier 1 --force") [ -z "${FAIL_DELETE:-}" ] ;;
esac
STUB

chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

APP="$WORK/app"
mkdir -p "$APP/scripts"
cp "$REPO_DIR/scripts/lib.sh" "$REPO_DIR/scripts/check-secrets.sh" \
    "$REPO_DIR/scripts/headscale-nodes.sh" "$APP/scripts/"

# good is in sync, root needs privileges the caller lacks, drifted has drifted.
cat >"$APP/scripts/rotate-secret.sh" <<'STUB'
#!/bin/sh
case "$1" in
    --list) printf '%s\n' ${STUB_TARGETS-good root drifted} ;;
    good) exit 0 ;;
    root) exit 2 ;;
    *) exit 1 ;;
esac
STUB

printf 'EMAIL=ops@example.test\n' >"$APP/.env"

# Sets $out, $rc and $calls.
run() {
    : >"$CALLS"
    rc=0
    out="$(env -u PROJECT_DIR -u ENV_FILE -u EMAIL "$@" 2>&1)" || rc=$?
    calls="$(cat "$CALLS")"
}

# --- check-secrets --------------------------------------------------------------

run sh "$APP/scripts/check-secrets.sh"
ok "a drifted secret fails the check" "$rc" 1
ok "every target is reported" "$out" "$(cat <<'EOF'
  ✔ good
  · root (not verifiable here)
  ✘ drifted - run: make rotate-secret TARGET=drifted
EOF
)"
if [ "$(id -u)" != "0" ]; then
    contains "  each through sudo" "$calls" "sudo /bin/sh $APP/scripts/rotate-secret.sh good --check"

    run env SUDO_FAILS=1 sh "$APP/scripts/check-secrets.sh"
    ok "a sudo that cannot authenticate fails the check" "$rc" 1
    lacks "  without reporting any secret as drifted" "$out" "✘"
fi

run sh "$APP/scripts/check-secrets.sh" --without-sudo
contains "--without-sudo says what sudo would verify" "$out" "· root (not verifiable without sudo)"
lacks "  and never calls it" "$calls" "sudo"

run env STUB_TARGETS="good root" sh "$APP/scripts/check-secrets.sh"
ok "no drift passes the check" "$rc" 0

run env STUB_TARGETS="" sh "$APP/scripts/check-secrets.sh"
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "an empty target list is an error, not a pass" "$failed" yes

run sh "$APP/scripts/check-secrets.sh" --bogus
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "an unknown argument is refused" "$failed" yes

# --- headscale-register ----------------------------------------------------------

run sh "$APP/scripts/headscale-nodes.sh" register ""
ok "a missing key is refused" "$rc" 1
contains "  by name" "$out" "Key missing"
ok "  before docker is called" "$calls" ""

run sh "$APP/scripts/headscale-nodes.sh" register abc123
ok "a key registers the node under EMAIL" "$calls" \
    "docker compose run --rm headscale nodes register --key abc123 --user ops@example.test"

run env EMAIL=other@example.test sh "$APP/scripts/headscale-nodes.sh" register abc123
contains "an exported EMAIL wins over .env" "$calls" "--user other@example.test"

# --- headscale-reset --------------------------------------------------------------

# Usage: reset <answer> [FAIL_DELETE=1|FAIL_LIST=1]
reset() {
    : >"$CALLS"
    rc=0
    out="$(printf '%s\n' "$1" | env -u PROJECT_DIR -u ENV_FILE ${2:-} \
        sh "$APP/scripts/headscale-nodes.sh" reset 2>&1)" || rc=$?
    calls="$(cat "$CALLS")"
}

reset no
ok "anything but yes aborts the reset" "$rc" 1
ok "  before docker is called" "$calls" ""

reset yes
ok "yes resets" "$rc" 0
contains "  every node is deleted" "$calls" "nodes delete --identifier 2 --force"
contains "  every preauth key expired" "$calls" "preauthkeys expire --id 7 --force"
contains "  and headscale restarted" "$calls" "docker compose restart headscale"

reset yes FAIL_DELETE=1
contains "a node that will not delete is named" "$out" "node 1 was not deleted"
contains "  and the reset carries on" "$calls" "preauthkeys expire --id 7 --force"
ok "  but does not report success" "$rc" 1

reset yes FAIL_LIST=1
contains "a listing that fails is named" "$out" "could not list the nodes"
lacks "  not reported as a completed reset" "$out" "reset complete"
ok "  and fails the command" "$rc" 1

run sh "$APP/scripts/headscale-nodes.sh" bogus
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "an unknown subcommand is refused" "$failed" yes

printf 'operator-commands-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
