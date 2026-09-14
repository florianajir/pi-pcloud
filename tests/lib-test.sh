#!/bin/sh
# Tests for the parts of scripts/lib.sh that own a file on disk.
#
# lib.sh had no test file of its own: its helpers were covered only through the
# hooks that call them, which is fine while each hook does its own writing and
# useless once the writing moves in here. ensure_env_secrets now owns every
# generated env file in the stack, so a bug in it is a bug in every service
# that has one at once.
#
# Everything runs against files under a throwaway directory. Run with `make test`.
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

# PROJECT_DIR is the repository so fix_ownership reads a real owner off it; the
# files under test all live in $WORK. ENV_FILE is set because lib.sh derives it
# and nothing here should ever reach the real .env.
PROJECT_DIR="$REPO_DIR"
ENV_FILE="$WORK/.env"
SCRIPT_NAME=lib-test
export PROJECT_DIR ENV_FILE SCRIPT_NAME

# shellcheck source=scripts/lib.sh disable=SC1091
. "$REPO_DIR/scripts/lib.sh" >/dev/null 2>&1

value_of() {
    read_env_value_from_file "$1" "$2"
}

# --- it writes what was asked for -------------------------------------------

FILE="$WORK/one/service.env"
ensure_env_secrets "$FILE" ONE_TOKEN >/dev/null 2>&1

ok "the file is created"          "$([ -f "$FILE" ] && echo yes)" yes
ok "the key is present"           "$(value_of "$FILE" ONE_TOKEN | wc -c)" 65
ok "and is 32 bytes of hex"       "$(value_of "$FILE" ONE_TOKEN | tr -d '0-9a-f' | wc -c)" 1
ok "the mode is 600"              "$(stat -c %a "$FILE")" 600

# The header names the caller, not lib.sh: `grep -rl "Managed by"` over config/
# is how you find which hook owns a generated file, and it has to keep working
# now that the writing happens one level down.
ok "the header names the caller"  "$(head -1 "$FILE" | grep -c 'Managed by scripts/lib-test.sh')" 1

# --- it does not rotate what is already there -------------------------------
#
# The failure this guards: a hook that regenerates on every start hands every
# consumer a new secret every boot, and the ones that froze the old value at
# container creation keep presenting it. Silent, and only visible as auth
# failures somewhere else entirely.

BEFORE="$(value_of "$FILE" ONE_TOKEN)"
ensure_env_secrets "$FILE" ONE_TOKEN >/dev/null 2>&1
ok "a second run keeps the value" "$(value_of "$FILE" ONE_TOKEN)" "$BEFORE"

# --- several keys, and a partial file ---------------------------------------

PAIR="$WORK/two/service.env"
ensure_env_secrets "$PAIR" FIRST_KEY SECOND_KEY >/dev/null 2>&1
FIRST="$(value_of "$PAIR" FIRST_KEY)"
SECOND="$(value_of "$PAIR" SECOND_KEY)"

ok "both keys are written"        "$([ -n "$FIRST" ] && [ -n "$SECOND" ] && echo yes)" yes
ok "and differ from each other"   "$([ "$FIRST" != "$SECOND" ] && echo yes)" yes

# Per key, not all-or-nothing: a file that lost one key must regenerate that one
# and keep the other. Written all-or-nothing, restoring a truncated file would
# rotate a secret that was never lost.
grep -v '^SECOND_KEY=' "$PAIR" > "$PAIR.tmp" && mv "$PAIR.tmp" "$PAIR"
ensure_env_secrets "$PAIR" FIRST_KEY SECOND_KEY >/dev/null 2>&1
ok "the surviving key is kept"    "$(value_of "$PAIR" FIRST_KEY)" "$FIRST"
ok "the missing one is minted"    "$([ -n "$(value_of "$PAIR" SECOND_KEY)" ] && echo yes)" yes
ok "and is not the old value"     "$([ "$(value_of "$PAIR" SECOND_KEY)" != "$SECOND" ] && echo yes)" yes

# --- the directory a bind mount leaves behind -------------------------------
#
# Docker creates a directory when a bind mount's source does not exist, and
# recreates it on every start until something moves it aside. The env file then
# never exists, the service starts with no secret, and nothing says why.

STRAY="$WORK/three/service.env"
mkdir -p "$STRAY"
ensure_env_secrets "$STRAY" STRAY_TOKEN >/dev/null 2>&1
ok "a directory in the way is repaired" "$([ -f "$STRAY" ] && echo yes)" yes
ok "and the secret lands in it"         "$([ -n "$(value_of "$STRAY" STRAY_TOKEN)" ] && echo yes)" yes

# --- refusals ---------------------------------------------------------------

rc=0
ensure_env_secrets "$WORK/none.env" >/dev/null 2>&1 || rc=$?
ok "no key names is an error"     "$rc" 1
ok "and writes nothing"           "$([ -f "$WORK/none.env" ] && echo yes || echo no)" no

# --- it owns the whole file -------------------------------------------------
#
# Documented, not incidental: the rewrite is what makes it safe to run on every
# start. A service whose env file also carries hand-edited settings keeps its
# own hook, and this is the assertion that says so out loud.

printf 'HAND_EDITED=keepme\n' >> "$FILE"
ensure_env_secrets "$FILE" ONE_TOKEN >/dev/null 2>&1
ok "an unlisted key is dropped"   "$(value_of "$FILE" HAND_EDITED)" ""
ok "the managed one survives"     "$(value_of "$FILE" ONE_TOKEN)" "$BEFORE"

# Dropped, but not lost. A secret cannot be regenerated from nothing, so the one
# case that says the caller's key list is wrong must not also be the case that
# destroys the evidence.
aside="$(ls "$(dirname "$FILE")" | grep '\.bak\.' | head -1)"
ok "and a copy is kept"           "$([ -n "$aside" ] && echo yes)" yes
ok "holding the dropped value"    "$(value_of "$(dirname "$FILE")/$aside" HAND_EDITED)" keepme
ok "readable only by its owner"   "$(stat -c %a "$(dirname "$FILE")/$aside")" 600

# And the common case stays quiet: a file holding exactly what was asked for
# leaves no copies behind, or every start would litter config/.
rm -f "$(dirname "$FILE")"/*.bak.*
ensure_env_secrets "$FILE" ONE_TOKEN >/dev/null 2>&1
ok "no copy when nothing is dropped" "$(ls "$(dirname "$FILE")" | grep -c '\.bak\.')" 0

printf '\nlib-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
