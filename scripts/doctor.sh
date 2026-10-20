#!/bin/sh
# `make doctor`: what is outside its threshold, which memory ceilings actually
# bind, and whether every secret still agrees with its consumers.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

# The same endpoint the assistant calls for the `anomalies` topic, so the shell
# and the chat cannot disagree. Asked from inside the container because
# system-tools only exposes its port on the compose networks, and with python3
# because the image (python:3.14-slim) ships no curl - the same call its
# healthcheck makes.
report_anomalies() {
    echo "🩺 Diagnostic"
    compose exec -T system-tools python3 -c \
        "import urllib.request as r; print(r.urlopen('http://localhost:8000/status/anomalies').read().decode())" \
        || echo "❌ system-tools unreachable - check 'docker compose ps' and 'make logs'"
}

# Read on the host, not through system-tools: the anomalies above answer "is
# the machine in trouble", a host-wide question, while this one is
# per-container and has no threshold to cross - a ceiling being hit costs a
# service its page cache and stalls nobody, so it never shows up in PSI and
# never belongs in a findings list. It is still the only way to tell a ceiling
# that is doing something from one that is decoration.
report_memory_ceilings() {
    echo "🧠 Memory ceilings"
    run_script ram-usage.sh report
}

# Without sudo, so `make doctor` stays non-interactive: a target that needs
# root reports "not verifiable" instead of prompting. Drift is reported, not a
# failure of the diagnostic itself.
report_secret_consistency() {
    echo "🔑 Secret consistency"
    run_script check-secrets.sh --without-sudo || true
}

report_anomalies
echo
report_memory_ceilings
echo
report_secret_consistency
