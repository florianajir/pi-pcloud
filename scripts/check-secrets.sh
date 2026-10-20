#!/bin/sh
# Whether each secret rotate-secret.sh manages still agrees with its consumers:
# `make check-secrets`, and the last block of `make doctor`. Drift is otherwise
# silent until a widget 401s or a backup cannot open its repository.
#
#   check-secrets.sh                 through sudo, so every target is verifiable
#   check-secrets.sh --without-sudo  never prompts: a target that needs root
#                                    says so instead
#
# Exits 1 when a secret has drifted. Changes nothing.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

case "$*" in
    "")
        AS="$SUDO"
        UNVERIFIABLE="not verifiable here"
        ;;
    --without-sudo)
        AS=""
        UNVERIFIABLE="not verifiable without sudo"
        ;;
    *) die "usage: $(basename "$0") [--without-sudo]" ;;
esac

require_env_file

# Authenticated once, up front: a sudo that cannot (no terminal, a wrong
# password) fails every check with status 1, which would read as every secret
# having drifted and advise rotating them all.
if [ -n "$AS" ]; then
    $AS -v || die "sudo could not authenticate; nothing was checked (--without-sudo skips it)"
fi

targets="$(run_script rotate-secret.sh --list)"
[ -n "$targets" ] || die "rotate-secret.sh --list named no target"

drift=0
for target in $targets; do
    status=0
    $AS /bin/sh "$SCRIPT_DIR/rotate-secret.sh" "$target" --check >/dev/null 2>&1 || status=$?
    case "$status" in
        0) echo "  ✔ $target" ;;
        2) echo "  · $target ($UNVERIFIABLE)" ;;
        *)
            echo "  ✘ $target - run: make rotate-secret TARGET=$target"
            drift=1
            ;;
    esac
done
exit "$drift"
