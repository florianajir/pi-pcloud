#!/bin/sh
# Watch the Authelia container log for failed authentication attempts and publish
# them to ntfy. Runs as a long-lived host service (pi-pcloud-authelia-ntfy.service),
# so no extra container is needed.
#
# Authelia has no webhook/event notifier (its notifier is SMTP-only, for user mails),
# so the log stream is the integration point. Matched messages:
#   Unsuccessful <method> authentication attempt by user '<user>'
#   Unsuccessful <method> authentication attempt by user '<user>' and they are banned until <time>
#   Error occurred getting details for user with username input '<user>' which usually
#     indicates they do not exist
#   Access Request failed with error: <reason>
set -eu

. "$(dirname "$0")/lib.sh"

NTFY_ENV_FILE="${NTFY_ENV_FILE:-$PROJECT_DIR/config/ntfy/ntfy.env}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
NTFY_CONTAINER="${NTFY_CONTAINER:-pi-ntfy}"
NTFY_USER="${AUTHELIA_NTFY_USER:-authelia}"
# Collapse identical (kind, user, ip) events inside this window to keep a browser
# retry loop or a slow brute-force from turning into a notification storm.
DEDUPE_WINDOW="${AUTHELIA_NTFY_DEDUPE_WINDOW:-60}"
# A client left holding a dead refresh token retries for as long as it is open -
# every few minutes, for days. An hour-wide window keeps that one fault to a
# handful of reminders instead of hundreds.
OIDC_DEDUPE_WINDOW="${AUTHELIA_NTFY_OIDC_DEDUPE_WINDOW:-3600}"
# How many recent keys each family remembers. One slot is not enough: several
# sources can be failing at once - every OIDC client has its own container IP -
# and with a single slot they alternate, every key looks new, and every retry
# notifies. That is the storm the windows above exist to prevent.
SEEN_MAX="${AUTHELIA_NTFY_SEEN_MAX:-32}"
# After a failed publish, hold off this long before attempting another. A hanging
# ntfy would otherwise cost every matching line a full curl timeout and the
# watcher would fall behind the log stream it is following.
PUBLISH_RETRY_DELAY="${AUTHELIA_NTFY_PUBLISH_RETRY_DELAY:-60}"
RECONNECT_DELAY="${AUTHELIA_NTFY_RECONNECT_DELAY:-10}"

# --- ntfy publishing ---

# Usage: publish <title> <priority> <tags> <message>
# Returns non-zero when the notification did not go out, so the caller can leave
# its dedupe slot unstamped and let the next occurrence try again.
publish() {
    _password="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_AUTHELIA_PASSWORD)"
    _topic="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_AUTHELIA_TOPIC)"
    [ -n "$_topic" ] || _topic="security"

    if [ -z "$_password" ]; then
        log "WARNING: NTFY_AUTHELIA_PASSWORD missing from $NTFY_ENV_FILE; skipping notification"
        return 1
    fi

    ntfy_publish "$NTFY_USER" "$_password" "$_topic" "$1" "$2" "$3" "$4"
}

# --- Log parsing ---

# Usage: field <sed-expression> <line>
field() {
    printf '%s\n' "$2" | sed -n "$1" | head -n1
}

# A ring is newline-separated "<epoch> <key>" entries, newest last.

# Usage: ring_prune <ring> <now> <window> - prints the ring without stale entries.
ring_prune() {
    _rp_now="$2"
    _rp_window="$3"

    printf '%s\n' "$1" | while IFS=' ' read -r _rp_time _rp_key; do
        case "$_rp_time" in ''|*[!0-9]*) continue ;; esac
        [ $((_rp_now - _rp_time)) -lt "$_rp_window" ] || continue
        printf '%s %s\n' "$_rp_time" "$_rp_key"
    done
}

# Usage: ring_has <ring> <key>
ring_has() {
    printf '%s\n' "$1" | cut -d' ' -f2- | grep -qxF -- "$2"
}

# Usage: ring_add <ring> <now> <key> - prints the ring with <key> appended, capped.
ring_add() {
    printf '%s\n%s %s\n' "$1" "$2" "$3" | grep -v '^$' | tail -n "$SEEN_MAX"
}

notify_event() {
    _kind="$1"
    _user="$2"
    _ip="$3"
    _method="$4"
    _path="$5"
    _time="$6"
    _detail="$7"

    [ -n "$_user" ] || _user="<unknown>"
    [ -n "$_ip" ] || _ip="<unknown>"

    # Deduplicate repeats of the same event within the window for its kind. The
    # two families keep separate slots: with one shared slot, a login failure
    # landing mid-loop would flush the hour-wide OIDC suppression and re-notify.
    #
    # The reason joins the key for OIDC only. There the user is always unknown and
    # the IP is one stable container address, so without it the key collapses to a
    # single slot per client and a fault that changes cause mid-window - a rotated
    # secret after a dead refresh token - would go unheard for the rest of the hour.
    # Bans keep it out: their detail is an expiry that moves on every attempt.
    _key="$_kind|$_user|$_ip"
    [ "$_kind" != oidc_grant ] || _key="$_key|$_detail"
    _now="$(date +%s)"
    case "$_kind" in
        oidc_grant)
            _window="$OIDC_DEDUPE_WINDOW"
            _ring="$(ring_prune "${oidc_seen:-}" "$_now" "$_window")"
            ;;
        *)
            _window="$DEDUPE_WINDOW"
            _ring="$(ring_prune "${login_seen:-}" "$_now" "$_window")"
            ;;
    esac

    if ring_has "$_ring" "$_key"; then
        log "Suppressed duplicate event ($_kind) within ${_window}s window"
        return 0
    fi

    # Nothing is stamped while ntfy is failing, so without this the watcher would
    # pay a curl timeout per matching line and drift behind docker logs -f.
    if [ $((_now - ${last_publish_fail:-0})) -lt "$PUBLISH_RETRY_DELAY" ]; then
        log "Holding off ($_kind): a publish failed less than ${PUBLISH_RETRY_DELAY}s ago"
        return 0
    fi

    # A rejected grant has no resolved subject, so Authelia logs no username on
    # that line: the client IP is all the alert can lead with.
    if [ "$_kind" = oidc_grant ]; then
        _message="IP: $_ip"
    else
        _message="User: $_user
IP: $_ip"
    fi
    [ -z "$_method" ] || _message="$_message
Method: $_method"
    [ -z "$_path" ] || _message="$_message
Endpoint: $_path"
    [ -z "$_time" ] || _message="$_message
Time: $_time"

    _published=0
    case "$_kind" in
        banned)
            _message="$_message
Banned until: $_detail"
            publish "Authelia: user banned" high "lock,rotating_light" "$_message" || _published=1
            ;;
        unknown_user)
            publish "Authelia: unknown user login attempt" default "warning,detective" "$_message" || _published=1
            ;;
        oidc_grant)
            _message="$_message
Reason: $_detail"
            publish "Authelia: OIDC grant rejected" default "key,warning" "$_message" || _published=1
            ;;
        *)
            publish "Authelia: failed login" default "warning" "$_message" || _published=1
            ;;
    esac

    # Remember the key only once the alert is actually out. Marking it before would
    # let one ntfy hiccup silence the whole window - an hour, for a rejected grant,
    # which is exactly the alert meant to catch a vault locked out in minutes.
    if [ "$_published" -ne 0 ]; then
        last_publish_fail="$_now"
        return 0
    fi
    last_publish_fail=0

    case "$_kind" in
        oidc_grant) oidc_seen="$(ring_add "$_ring" "$_now" "$_key")" ;;
        *) login_seen="$(ring_add "$_ring" "$_now" "$_key")" ;;
    esac
}

process_line() {
    _line="$1"

    case "$_line" in
        *'Unsuccessful '*' authentication attempt by user '*) ;;
        *'username input '*'which usually indicates they do not exist'*) ;;
        *'Access Request failed with error'*) ;;
        *) return 0 ;;
    esac

    _ip="$(field 's|.* remote_ip=\([^ ]*\).*|\1|p' "$_line")"
    _path="$(field 's|.* path=\([^ ]*\).*|\1|p' "$_line")"
    _time="$(field 's|^time="\([^"]*\)".*|\1|p' "$_line")"

    case "$_line" in
        *'Access Request failed with error'*)
            _reason="$(field 's|.*Access Request failed with error: ||p' "$_line")"
            # Stop at the quote closing msg, whatever field logrus sorted next. It
            # sorts them alphabetically, so anchoring on " method=" would break the
            # day a field sorting earlier appears - and an unparsed reason is not
            # cosmetic here: it joins the dedupe key, collapsing every distinct
            # cause into one slot for the whole window.
            _reason="$(printf '%s' "$_reason" | sed -e 's|" [a-z_]*=.*||' -e 's|"$||')"
            # Drop the RFC 6749 boilerplate that opens invalid_grant so the alert
            # leads with the part that differs between causes. Only when something
            # follows it: a message that is nothing but the preamble keeps it.
            _stripped="$(printf '%s' "$_reason" | sed 's|.*was issued to another client\. ||')"
            [ -z "$_stripped" ] || _reason="$_stripped"
            [ -n "$_reason" ] || _reason="<unparsed>"
            notify_event oidc_grant "" "$_ip" "" "$_path" "$_time" "$_reason"
            return 0
            ;;
    esac

    case "$_line" in
        *'which usually indicates they do not exist'*)
            _user="$(field "s|.*username input '\([^']*\)'.*|\1|p" "$_line")"
            notify_event unknown_user "$_user" "$_ip" "" "$_path" "$_time" ""
            return 0
            ;;
    esac

    _user="$(field "s|.*authentication attempt by user '\([^']*\)'.*|\1|p" "$_line")"
    _method="$(field 's|.*Unsuccessful \([^ ]*\) authentication attempt.*|\1|p' "$_line")"

    # A nonexistent username yields an empty user here, immediately followed by the
    # "username input '<user>'" line that carries the attempted name - notify on that
    # one instead so the alert is not anonymous.
    if [ -z "$_user" ]; then
        return 0
    fi

    case "$_line" in
        *'and they are banned until '*)
            _banned_until="$(field 's|.*banned until \([^"]*\)".*|\1|p' "$_line")"
            notify_event banned "$_user" "$_ip" "$_method" "$_path" "$_time" "$_banned_until"
            ;;
        *)
            notify_event failed "$_user" "$_ip" "$_method" "$_path" "$_time" ""
            ;;
    esac
}

# --- Main loop ---

watch_stream() {
    # --tail 0 follows only new lines: a watcher restart never replays old attempts.
    docker logs -f --tail 0 "$AUTHELIA_CONTAINER" 2>&1 | while IFS= read -r line; do
        process_line "$line" || true
    done
}

main() {
    log "Watching $AUTHELIA_CONTAINER for failed authentication attempts"

    while :; do
        if container_is_running "$AUTHELIA_CONTAINER"; then
            watch_stream || true
            log "Log stream ended; reconnecting in ${RECONNECT_DELAY}s"
        fi
        sleep "$RECONNECT_DELAY"
    done
}

main "$@"
