#!/bin/sh
# Function-level tests for scripts/pi-pcloud.
#
# `make` is stubbed on PATH, so every case asserts what the dispatcher would
# have run without running it — no container, no systemd, no host change.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
CLI="$REPO_DIR/scripts/pi-pcloud"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=tests/testlib.sh
. "$(dirname "$0")/testlib.sh"

# Kept for the help cases, which need the Makefile actually parsed.
REAL_MAKE="$(command -v make)"

# A make that reports what it was asked to do, and answers the dispatcher's
# `make -n <target>` probe from a fixed list of known targets.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/make" <<'STUB'
#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = "-n" ]; then
        target="$(eval printf '%s' "\${$#}")"
        case "$target" in
            start | stop | status | logs | config | services | doctor) exit 0 ;;
            enable | disable | headscale-register) exit 0 ;;
            *) exit 1 ;;
        esac
    fi
done
printf 'MAKE %s\n' "$*"
STUB
chmod +x "$WORK/bin/make"
PATH="$WORK/bin:$PATH"
export PATH

cli() { PI_PCLOUD_DIR="$REPO_DIR" sh "$CLI" "$@" 2>&1 || true; }

# --- dispatch ---------------------------------------------------------------

ok "no argument shows help"   "$(cli)"          "MAKE --no-print-directory -C $REPO_DIR help"
ok "help is forwarded"        "$(cli help)"     "MAKE --no-print-directory -C $REPO_DIR help"
ok "a plain command passes"   "$(cli status)"   "MAKE --no-print-directory -C $REPO_DIR status"
ok "logs passes through"      "$(cli logs)"     "MAKE --no-print-directory -C $REPO_DIR logs"

# Arguments reach make untouched: the Makefile takes them positionally, so
# there is no s=<service> translation left in the wrapper to get wrong.
ok "enable takes a service"   "$(cli enable stremio)" \
    "MAKE --no-print-directory -C $REPO_DIR enable stremio"
ok "disable takes a service"  "$(cli disable stremio)" \
    "MAKE --no-print-directory -C $REPO_DIR disable stremio"
ok "enable without a service still forwards" "$(cli enable)" \
    "MAKE --no-print-directory -C $REPO_DIR enable"
ok "headscale-register takes a key" "$(cli headscale-register abc123)" \
    "MAKE --no-print-directory -C $REPO_DIR headscale-register abc123"

# An unknown command must not surface a raw make failure.
out="$(cli no-such-command)"
case "$out" in
    *"unknown command no-such-command"*) ok "unknown command is explained" yes yes ;;
    *) ok "unknown command is explained" "$out" yes ;;
esac
PI_PCLOUD_DIR="$REPO_DIR" sh "$CLI" no-such-command >/dev/null 2>&1 && rc=0 || rc=$?
ok "unknown command exits 2" "$rc" 2

# --- the lists behind completion --------------------------------------------

case "$(cli --list-commands | tr '\n' ' ')" in
    *start*stop*) ok "commands come from the Makefile" yes yes ;;
    *) ok "commands come from the Makefile" "$(cli --list-commands | tr '\n' ' ')" yes ;;
esac
case "$(cli --list-services | tr '\n' ' ')" in
    *stremio*) ok "services come from compose.yaml" yes yes ;;
    *) ok "services come from compose.yaml" "$(cli --list-services | tr '\n' ' ')" yes ;;
esac

# --- help covers every command ----------------------------------------------

# `make help` is generated from the `## ` comment on each target, so a target
# without one is a command help leaves out.
undocumented="$(grep -E '^[a-z][a-z0-9-]*:' "$REPO_DIR/Makefile" | grep -v '## ' |
    cut -d: -f1 | tr '\n' ' ' || true)"
ok "every command has a help line" "$undocumented" ""

help="$("$REAL_MAKE" --no-print-directory -s -C "$REPO_DIR" help)"
case "$help" in
    *"rotate-secret TARGET=<name>  "*"check-secrets "*) ok "help lists commands with their arguments" yes yes ;;
    *) ok "help lists commands with their arguments" "$help" "rotate-secret TARGET=<name> ... check-secrets" ;;
esac

# A second argument has no rule, and make would only say so after the first
# goal's recipe ran. -n prints recipes and runs none.
out="$("$REAL_MAKE" -n -s -C "$REPO_DIR" enable stremio extra 2>&1 || true)"
case "$out" in
    *"enable takes one argument, got: stremio extra"*) ok "a second argument is refused" yes yes ;;
    *) ok "a second argument is refused" "$out" "enable takes one argument, got: stremio extra" ;;
esac
lacks_recipe="$(printf '%s\n' "$out" | grep -c 'services.sh' || true)"
ok "  before any recipe runs" "$lacks_recipe" 0

# --- finding the checkout ---------------------------------------------------

# Installed shape: a symlink on PATH, with no PI_PCLOUD_DIR to help.
ln -sfn "$CLI" "$WORK/bin/pi-pcloud"
ok "resolves the checkout through the symlink" \
    "$(env -u PI_PCLOUD_DIR sh "$WORK/bin/pi-pcloud" status 2>&1 || true)" \
    "MAKE --no-print-directory -C $REPO_DIR status"

out="$(PI_PCLOUD_DIR="$WORK/empty" sh "$CLI" status 2>&1 || true)"
case "$out" in
    *"not a pi-pcloud checkout"*) ok "a wrong PI_PCLOUD_DIR is refused" yes yes ;;
    *) ok "a wrong PI_PCLOUD_DIR is refused" "$out" yes ;;
esac

finish
