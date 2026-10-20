#!/bin/sh
# Refresh the running stack in place: `make update` and `make update-images`.
#
#   update.sh            pull the repository, then apply what the pull changed
#   update.sh --images   images only: no pull, no host files, no watcher restart
#
# Images are refreshed while the stack runs, so nothing is interrupted until
# compose swaps the containers that actually have a new image.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

UNIT=pi-pcloud.service
WATCH_UNIT=pi-pcloud-authelia-ntfy.service
# The commit this update applies changes from, and how far it got: none, then
# images once local images may be rebuilt, then host once host files and
# containers may run the new version.
UPDATE_BASE=""
STAGE=none
UPDATE_RECORD=""

# Through make: the required-variable list lives in the Makefile, where
# install.sh reads it too.
check_env() {
    make --no-print-directory check-env
}

# Compose pulls every image at once, and GHCR (lscr.io included) answers that
# burst with `toomanyrequests` for a dozen images at a time. Every image the
# failed attempt did fetch is local by the next one, so a retry asks for far
# less. Same three attempts as CI's pull step. `pull` skips the images built
# here, which `build --pull` rebuilds against their updated bases.
refresh_images() {
    local attempt=1
    until docker compose pull --ignore-buildable; do
        if [ "$attempt" -ge 3 ]; then
            echo "❌ Image pull failed after 3 attempts"
            exit 1
        fi
        echo "  ⚠ pull attempt $attempt/3 failed; retrying in $((attempt * 20))s..."
        sleep $((attempt * 20))
        attempt=$((attempt + 1))
    done
    echo "🔨 Locally built images..."
    docker compose build --pull
}

# Through systemd when the unit is inactive, so the stack never runs behind an
# `inactive` unit; directly otherwise, since `start` on an already-active
# oneshot is a no-op. Root either way: the hooks write root-owned config, and
# headscale's leaves orphan API keys when run as a user.
apply_stack() {
    if $SUDO systemctl is-active --quiet "$UNIT"; then
        $SUDO sh "$SCRIPT_DIR/stack-up.sh"
    else
        $SUDO systemctl start "$UNIT"
    fi
}

# `up -d` compares a container's image and spec, never the contents of the files
# bind-mounted into it, so a config the pull rewrote would sit on disk unread.
# changed-services.sh names the services that read what changed; a path it
# cannot attribute, or a failure to answer at all, costs a full restart.
#
# The recreate comes after apply_stack, whose pre-start hooks are what render
# the new config. The wait after it keeps the success line honest, and `--wait`
# is safe here: unlike stack-up.sh, this is no systemd ExecStart whose failure
# is followed by `compose down`. Two calls, because one `--wait` returns the
# same status for a container compose could not create and one merely slow to
# go healthy - the first fails the update, the second only warns.
# shellcheck disable=SC2086 # $targets is split on purpose, one service per word
apply_pulled_changes() {
    local targets=""
    targets="$(run_script changed-services.sh "$UPDATE_BASE" HEAD)" || targets=ALL
    if [ "$targets" = ALL ]; then
        echo "🔁 The pull changed something no single service owns; restarting the stack..."
        $SUDO systemctl restart "$UNIT"
        return 0
    fi
    echo "🚀 Applying changes (only what moved is recreated)..."
    apply_stack
    [ -n "$targets" ] || return 0
    echo "🔁 Re-reading changed config:" $targets
    $SUDO docker compose up -d --no-deps --force-recreate $targets
    $SUDO docker compose up -d --no-deps --wait --wait-timeout 180 $targets \
        || echo "  ⚠ recreated, but not healthy within 180s:" $targets
}

reclaim_space() {
    echo "🧹 Reclaiming space from the replaced images..."
    docker image prune -f | tail -n1
}

# An update that moved the checkout keeps its start commit and stage here until
# it completes. The next run finds the pull already done, so its own range would
# be empty and nothing the first pull changed would be recreated; it reads this
# instead. Written at every step rather than from the failure trap, which a
# hangup, an OOM kill or a power cut never runs. Under .git: never tracked.
record_progress() {
    [ "$UPDATE_BASE" != "$(git rev-parse HEAD)" ] || return 0
    { printf '%s %s\n' "$UPDATE_BASE" "$STAGE" >"$UPDATE_RECORD"; } 2>/dev/null || return 1
    fix_ownership "$UPDATE_RECORD"
}

# A resumed run starts at the stage the failed one reached, so stages only move
# forward from there.
enter_stage() {
    [ "$STAGE" = host ] || STAGE="$1"
    record_progress || true
}

# Picks up an earlier update that failed past its pull, as long as its start
# commit is still behind HEAD. One that is not (the checkout was reset since)
# describes nothing here any more. A record without a stage counts as the worst.
resume_failed_update() {
    local head="" stored="" stored_stage=""
    head="$(git rev-parse HEAD)"
    UPDATE_BASE="$head"
    [ -f "$UPDATE_RECORD" ] || return 0
    read -r stored stored_stage <"$UPDATE_RECORD" || true
    if [ -n "$stored" ] && [ "$stored" != "$head" ] &&
        git merge-base --is-ancestor "$stored" "$head" 2>/dev/null; then
        UPDATE_BASE="$stored"
        STAGE="${stored_stage:-host}"
        echo "  ↻ resuming the update that failed after pulling from $(git rev-parse --short "$UPDATE_BASE")"
    fi
}

# Nothing reverts a half-applied update. Running it again is the usual way out,
# and resumes from UPDATE_BASE; going back costs only what the failed run had
# already touched - never `make update`, whose pull would move forward again.
explain_failure() {
    local base="" applied="" way_back=""
    echo "❌ Update failed."
    [ "$(git rev-parse HEAD)" != "$UPDATE_BASE" ] || return 0
    base="$(git rev-parse --short "$UPDATE_BASE")"
    case "$STAGE" in
        none)
            applied="Nothing was applied yet."
            way_back="git reset --hard $UPDATE_BASE" ;;
        images)
            applied="Nothing was applied to the running stack; locally built images may be rebuilt."
            way_back="git reset --hard $UPDATE_BASE && docker compose build" ;;
        *)
            applied="Host files and containers may already run the new version."
            way_back="git reset --hard $UPDATE_BASE && make install-system && docker compose build && make restart" ;;
    esac
    echo "   This checkout is on $(git rev-parse --short HEAD); the update started from $base."
    echo "   $applied"
    if record_progress; then
        echo "   ↻ Fix the cause above and run \`make update\` again: it resumes from $base."
    else
        echo "   ⚠ Could not record $base for the next run: after fixing the cause, run \`make update\`, then \`make restart\`."
    fi
    echo "   ↩ Or go back: $way_back"
}

update_from_repository() {
    local branch=""
    echo "🔄 Updating pi-pcloud..."
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = main ] || echo "  ⚠ on branch $branch, not main"
    UPDATE_RECORD="$(git rev-parse --git-path pi-pcloud-update-base)"
    resume_failed_update
    trap explain_failure EXIT
    # dash skips the EXIT trap when a signal kills it: a Ctrl-C during the long
    # image pull would otherwise leave the moved checkout with no way back.
    trap 'exit 1' INT TERM
    echo "📥 Repository..."
    git pull --ff-only
    record_progress || true
    check_env
    echo "📦 Images (the stack keeps running)..."
    enter_stage images
    refresh_images
    enter_stage host
    run_script install-system.sh
    # The watcher runs on the host, outside compose, so nothing above picks up a
    # change to its script. try-restart leaves it alone when it is not running.
    $SUDO systemctl try-restart "$WATCH_UNIT"
    apply_pulled_changes
    reclaim_space
    trap - EXIT
    rm -f "$UPDATE_RECORD"
    echo "✅ Update complete"
}

update_images() {
    echo "📦 Updating images (the stack keeps running)..."
    check_env
    refresh_images
    echo "🚀 Recreating the containers whose image moved..."
    apply_stack
    reclaim_space
    echo "✅ Images up to date"
}

cd "$PROJECT_DIR"
case "$*" in
    "") update_from_repository ;;
    --images) update_images ;;
    *) die "usage: $(basename "$0") [--images]" ;;
esac
