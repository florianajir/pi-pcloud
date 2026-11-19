#!/bin/sh
# Pull the images the selected profiles need. `make update`, `make update-images`
# and CI's smoke test all go through here, so a pull that passes in CI is the
# pull the Pi runs.
#
# Plain `compose pull` cancels every pull in flight at its first error: one
# connection reset on one blob throws away the other forty images, and the
# retry starts nearly from scratch. Each attempt is therefore two passes. The
# first fetches everything it can and lets failures go; the strict second one
# is left with only what is still missing, and its error names the image.
#
# An image the first pass could not refresh but that is already local at the
# tag the checkout asks for is kept, so one registry being down does not block
# an update that does not move its image. One that is not local is retried, on
# a backoff spanning about eight minutes: registries do go away that long.
#
# --ignore-buildable: update.sh rebuilds the images built here with
# `build --pull`.

set -eu

MAX_ATTEMPTS=6

pull_what_it_can() {
    docker compose pull --ignore-buildable --policy "$1" --ignore-pull-failures
}

pull_what_is_missing() {
    docker compose pull --ignore-buildable --policy missing
}

attempt=1
delay=15
pull_what_it_can always
until pull_what_is_missing; do
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "❌ Image pull failed after $MAX_ATTEMPTS attempts"
        exit 1
    fi
    echo "  ⚠ pull attempt $attempt/$MAX_ATTEMPTS left images missing; retrying in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    pull_what_it_can missing
done
