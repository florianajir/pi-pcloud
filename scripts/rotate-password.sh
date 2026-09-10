#!/bin/sh
# Rotate the shared PASSWORD (.env) and push the new value into every service
# that actually stores its own persisted copy, not just the ones that read
# ${PASSWORD} fresh from the environment at container start.
#
# Use this after PASSWORD has been exposed (leaked, shoulder-surfed, committed,
# etc). It does NOT rotate ADMIN_USER, EMAIL, or any of the independent
# per-service secrets (NTFY_*_PASSWORD, Comet's config/comet/comet.env, Backrest's
# config/backrest/backrest.env, the Vaultwarden admin token, OIDC client secrets,
# S3/backup keys) - those aren't derived from PASSWORD and don't need touching here.
#
# Lessons baked in from doing this rotation live on this exact stack once:
#   - The LLDAP admin account's password is NOT "self-healing" on container
#     recreate, despite docs/CONFIGURATION.md's old claim. Recreating lldap
#     with a new LLDAP_LDAP_USER_PASS does nothing to the already-provisioned
#     admin user. The only way to actually change it is the LDAP
#     password-modify extended operation (ldappasswd), authenticated with the
#     OLD password.
#   - Authelia's real Postgres credential is the `db_password` SECRET FILE
#     (referenced by configuration.yml.template), not the AUTHELIA_DB_PASSWORD
#     env var in compose.yaml (that env var is effectively vestigial/unused by
#     Authelia itself). Writing it before the `authelia` Postgres role is
#     actually rotated makes Authelia crash-loop on DB ping.
#   - Nextcloud's DB password lives in config.php, written once at install.
#     You MUST update it via `occ config:system:set dbpassword` while the OLD
#     Postgres role password is still valid (i.e. BEFORE rotating the
#     `nextcloud` role), or Nextcloud loses its DB connection in the gap.
#   - .env's PASSWORD feeds Postgres connection strings for lldap,
#     immich-server, open-webui, vaultwarden, and backrest, AND local-login
#     fallbacks for pihole/homepage. Writing a new PASSWORD into .env
#     without also rotating the Postgres roles those services hold poisons .env
#     for a FUTURE, unrelated container recreate (a reboot, `make restart`, an
#     image bump) to break on - so --skip-postgres mode never touches .env at all.
#   - The authelia-config/secrets directory can end up owned by root (this
#     stack's systemd unit runs docker compose as root, and some root-run init
#     path can flip ownership between edits). Secret-file writes below try a
#     plain write first and fall back to sudo.
#
# Best-effort past the Postgres/LDAP/Authelia core: a partial rotation you can
# read the report for is safer to recover from than one that dies halfway with no
# summary. Fix up anything marked FAILED manually.
#
# Usage: sh scripts/rotate-password.sh [--yes] [--skip-postgres]
#   --yes             Skip the interactive confirmation (the Makefile target
#                      already confirms before calling this, so it passes
#                      --yes).
#   --skip-postgres    Rotate only the LLDAP admin account + Authelia's
#                      matching ldap_password secret (the actual SSO master
#                      credential). Touches nothing else, .env included - see
#                      the .env bullet above.

. "$(dirname "$0")/lib.sh"

# No `set -e` on purpose: under it, one transient curl/docker-exec failure inside
# a plain `var=$(cmd)` assignment would abort the ENTIRE rotation, including
# unrelated later steps. Each function guards its own risky commands instead.

ASSUME_YES=0
SKIP_POSTGRES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --skip-postgres) SKIP_POSTGRES=1 ;;
    esac
done

# Matches LLDAP_LDAP_BASE_DN in compose.yaml, which is not overridable via env.
LLDAP_BASE_DN="dc=home,dc=ldap"
LLDAP_ADMIN_USERNAME="admin"
# The backrest image, not osixia/openldap (archived 2021, and a whole LDAP server
# for two client binaries). The stack builds this one, so the tools are on disk:
# no registry fetch in the middle of a credential rotation.
LDAP_CLIENT_IMAGE="pi-backrest:local"

SUMMARY=""
note() {
    SUMMARY="${SUMMARY}$1
"
    log "$1"
}

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    echo ""
    if [ "$SKIP_POSTGRES" = "1" ]; then
        echo "⚠️  This will rotate the LLDAP admin password (the SSO master credential"
        echo "   Authelia uses to bind to LDAP) and update Authelia's matching secret."
        echo "   .env is NOT touched and no Postgres role or other service is rotated."
    else
        echo "⚠️  This will rotate PASSWORD everywhere it's persisted:"
        echo "   Postgres roles (postgres, immich, nextcloud, authelia, lldap, open-webui,"
        echo "   vaultwarden, freshrss), the LLDAP admin account (LDAP password-modify, not env),"
        echo "   Authelia's ldap_password + db_password secrets, Nextcloud (DB + admin"
        echo "   login), Pi-hole, Beszel, ntfy, qBittorrent, Prowlarr, Kapowarr, Dockhand,"
        echo "   and recreates the containers that bake it into their environment."
    fi
    echo "   Active sessions on Authelia/Nextcloud/etc. may be interrupted."
    echo ""
    printf "Type 'yes' to confirm: "
    read -r reply
    [ "$reply" = "yes" ] || { echo "Aborted"; exit 1; }
}

recreate() {
    local service="$1"
    local container="${2:-pi-$service}"
    if container_is_running "$container"; then
        if compose up -d --force-recreate --no-deps "$service" >/dev/null 2>&1; then
            note "✔ Recreated $service"
        else
            note "✘ FAILED to recreate $service (check 'docker compose logs $service')"
        fi
    else
        note "… Skipped $service (not running)"
    fi
}

# Plain write first, sudo fallback - see the ownership note in the file header.
write_secret_file() {
    local path="$1"
    local content="$2"
    if printf '%s' "$content" > "$path" 2>/dev/null; then
        safe_chmod 600 "$path"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && printf '%s' "$content" | sudo tee "$path" >/dev/null 2>&1; then
        sudo chmod 600 "$path" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Unlike write_secret_file, a backup failure is not swallowed - it's reported
# via the return code so callers can warn instead of silently proceeding with
# no safety net.
# One fixed .bak per secret, never timestamped: these hold the *previous*
# password in plaintext in a directory Backrest snapshots off-site, and nothing
# prunes them, so timestamps accumulate old credentials forever.
backup_secret_file() {
    local path="$1"
    local backup="$2"
    [ -f "$path" ] || return 0
    cp "$path" "$backup" 2>/dev/null && return 0
    sudo cp "$path" "$backup" 2>/dev/null && return 0
    return 1
}

# --- Postgres: generic role rotation + live auth verification ---
# ALTER ROLE takes effect immediately and leaves established connections alone;
# the only risk is a client still holding the OLD password failing its NEXT
# connection. Verification is a real auth check rather than "ALTER ROLE returned
# OK", because callers gate their dependent step on this return code.

rotate_postgres_role() {
    local role="$1"
    local db="$2"
    local sql_role="$role"
    case "$role" in
        open-webui) sql_role='"open-webui"' ;;
    esac

    # Statement on stdin, PGPASSWORD by name: both `-c "... '<password>'"` and
    # `env PGPASSWORD=<password>` land in the host's argv, once per role.
    if ! printf "ALTER ROLE %s WITH ENCRYPTED PASSWORD '%s';\n" \
        "$sql_role" "$(sql_escape "$NEW_PASSWORD")" |
        compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -q >/dev/null 2>&1; then
        note "✘ FAILED to rotate postgres role '$role'"
        return 1
    fi

    if PGPASSWORD="$NEW_PASSWORD" compose exec -T -e PGPASSWORD postgres \
        psql -U "$role" -d "$db" -h localhost -tAc "SELECT 1;" >/dev/null 2>&1; then
        note "✔ Rotated + verified postgres role '$role'"
        return 0
    fi

    note "✘ Rotated postgres role '$role' but verification connect FAILED - check manually"
    return 1
}

# The per-role *_ROLE_OK flags let main() gate each dependent step on whether THAT
# role rotated, not on whether the batch as a whole ran. `postgres` gets no flag:
# nothing else authenticates as it, so there is nothing to gate.
rotate_postgres_roles() {
    if ! container_is_running "pi-postgres"; then
        note "✘ SKIPPED all postgres roles (pi-postgres not running)"
        IMMICH_ROLE_OK=0; AUTHELIA_ROLE_OK=0; LLDAP_ROLE_OK=0; OPEN_WEBUI_ROLE_OK=0
        VAULTWARDEN_ROLE_OK=0; FRESHRSS_ROLE_OK=0
        return 0
    fi
    rotate_postgres_role postgres postgres
    rotate_postgres_role immich immich          && IMMICH_ROLE_OK=1     || IMMICH_ROLE_OK=0
    rotate_postgres_role authelia authelia      && AUTHELIA_ROLE_OK=1   || AUTHELIA_ROLE_OK=0
    rotate_postgres_role lldap lldap            && LLDAP_ROLE_OK=1      || LLDAP_ROLE_OK=0
    rotate_postgres_role open-webui open-webui  && OPEN_WEBUI_ROLE_OK=1 || OPEN_WEBUI_ROLE_OK=0
    rotate_postgres_role vaultwarden vaultwarden && VAULTWARDEN_ROLE_OK=1 || VAULTWARDEN_ROLE_OK=0
    # nextcloud is rotated in rotate_nextcloud_db_password() and freshrss in
    # rotate_freshrss(), each after its own config.php is updated - see the
    # ordering notes there.
}

# --- LLDAP: the actual admin login password (LDAP password-modify, not env) ---
# Recreating lldap with a new LLDAP_LDAP_USER_PASS does NOT reset an existing
# admin account's password, so use the LDAP password-modify extended operation,
# authenticated with the OLD password captured before any edits.

rotate_lldap_admin_password() {
    local bind_dn="uid=${LLDAP_ADMIN_USERNAME},ou=people,${LLDAP_BASE_DN}"

    if ! container_is_running "pi-lldap"; then
        note "✘ SKIPPED LLDAP admin password (pi-lldap not running)"
        LLDAP_ADMIN_OK=0
        return 1
    fi

    # -w/-s would put both the old and the new SSO master password in the
    # container's argv, which every local process can read out of /proc for the
    # length of the call. -y/-T read them from files instead; 0600 also keeps
    # ldappasswd from warning that the password file is publicly readable.
    local pw_dir=""
    local rc=1
    pw_dir="$(mktemp -d "${TMPDIR:-/tmp}/rotate-lldap.XXXXXX")" || {
        note "✘ FAILED to rotate LLDAP admin password (could not create a temp directory)"
        LLDAP_ADMIN_OK=0
        return 1
    }
    if ! (umask 077; printf '%s' "$OLD_PASSWORD" > "$pw_dir/old" &&
          printf '%s' "$NEW_PASSWORD" > "$pw_dir/new"); then
        note "✘ FAILED to rotate LLDAP admin password (could not stage the password files)"
        LLDAP_ADMIN_OK=0
        rm -rf "$pw_dir"
        return 1
    fi

    if docker run --rm --network frontend -v "$pw_dir:/pw:ro" --entrypoint ldappasswd "$LDAP_CLIENT_IMAGE" \
        -x -H ldap://pi-lldap:3890 -D "$bind_dn" -y /pw/old \
        -T /pw/new "$bind_dn" >/dev/null 2>&1; then
        if docker run --rm --network frontend -v "$pw_dir:/pw:ro" --entrypoint ldapwhoami "$LDAP_CLIENT_IMAGE" \
            -x -H ldap://pi-lldap:3890 -D "$bind_dn" -y /pw/new >/dev/null 2>&1; then
            note "✔ Rotated + verified LLDAP admin ($LLDAP_ADMIN_USERNAME) password"
            LLDAP_ADMIN_OK=1
            rc=0
        else
            note "✘ Rotated LLDAP admin password but verification bind FAILED - check manually"
            LLDAP_ADMIN_OK=0
        fi
    else
        note "✘ FAILED to rotate LLDAP admin password (old password may already be wrong, or bind DN '$bind_dn' is wrong for this deployment)"
        LLDAP_ADMIN_OK=0
    fi

    rm -rf "$pw_dir"
    return "$rc"
}

# --- Authelia secrets (files, not env - a restart re-reads them) ---
# Split in two and called at different points in main() because their
# dependencies differ: ldap_password needs only the LLDAP rotation, so it goes
# out immediately to keep the SSO outage short, while db_password is only safe to
# write once the `authelia` Postgres role has rotated.

rotate_authelia_ldap_secret() {
    local data_root secrets_dir

    if [ "$LLDAP_ADMIN_OK" != "1" ]; then
        note "… Skipped Authelia ldap_password update - LLDAP admin rotation did not succeed, leaving it unchanged so Authelia keeps binding with a password that still works"
        return 0
    fi

    data_root="$(resolve_data_location_path)"
    secrets_dir="$data_root/authelia-config/secrets"
    if [ ! -d "$secrets_dir" ]; then
        note "✘ SKIPPED Authelia ldap_password ($secrets_dir missing)"
        return 0
    fi

    if backup_secret_file "$secrets_dir/ldap_password" "$secrets_dir/ldap_password.bak"; then
        :
    else
        note "⚠ Could not back up Authelia ldap_password before overwriting it (proceeding anyway)"
    fi

    if write_secret_file "$secrets_dir/ldap_password" "$NEW_PASSWORD"; then
        note "✔ Rewrote Authelia ldap_password secret"
    else
        note "✘ FAILED to rewrite Authelia ldap_password (check ownership on $secrets_dir)"
        return 1
    fi

    if container_is_running "pi-authelia"; then
        if compose restart authelia >/dev/null 2>&1; then
            wait_for_health_warning "pi-authelia" 60 2 || true
            note "✔ Restarted Authelia to load new ldap_password"
        else
            note "✘ FAILED to restart Authelia (ldap_password written but not loaded - restart manually)"
        fi
    fi
}

rotate_authelia_db_secret() {
    local data_root secrets_dir

    if [ "$AUTHELIA_ROLE_OK" != "1" ]; then
        note "… Skipped Authelia db_password update - the 'authelia' Postgres role did not rotate, leaving db_password unchanged so Authelia doesn't crash-loop on its own DB ping"
        return 0
    fi

    data_root="$(resolve_data_location_path)"
    secrets_dir="$data_root/authelia-config/secrets"
    if [ ! -d "$secrets_dir" ]; then
        note "✘ SKIPPED Authelia db_password ($secrets_dir missing)"
        return 0
    fi

    if ! backup_secret_file "$secrets_dir/db_password" "$secrets_dir/db_password.bak"; then
        note "⚠ Could not back up Authelia db_password before overwriting it (proceeding anyway)"
    fi

    if write_secret_file "$secrets_dir/db_password" "$NEW_PASSWORD"; then
        note "✔ Rewrote Authelia db_password secret"
    else
        note "✘ FAILED to rewrite Authelia db_password (check ownership on $secrets_dir) - authelia role is rotated but the secret isn't, restart would crash-loop it"
        return 1
    fi

    if container_is_running "pi-authelia"; then
        if compose restart authelia >/dev/null 2>&1; then
            wait_for_health_warning "pi-authelia" 60 2 || true
            note "✔ Restarted Authelia to load new db_password"
        else
            note "✘ FAILED to restart Authelia (db_password written but not loaded - restart manually)"
        fi
    fi
}

# --- Nextcloud: config.php dbpassword + real admin account ---
# occ needs the OLD role password still valid to boot and write the new one into
# config.php, so config.php goes first and the ALTER ROLE follows. Nextcloud
# cannot reach its DB in the gap between the two, which self-heals immediately.

rotate_nextcloud_db_password() {
    NEXTCLOUD_ROLE_OK=0

    if ! container_is_running "pi-nextcloud"; then
        note "✘ SKIPPED Nextcloud dbpassword (pi-nextcloud not running)"
        return 0
    fi

    # Handed over on stdin, not on `--value=`, where it would sit in the process
    # table for the life of the exec. config:import merges: every config.php key
    # not named in the payload is left untouched. The OC_PASS this used to set
    # was dead — only the user:* commands read it, never config:system:set.
    if NEW_DB_PASSWORD="$NEW_PASSWORD" jq -nc '{system: {dbpassword: $ENV.NEW_DB_PASSWORD}}' \
        | docker exec -i pi-nextcloud php occ config:import >/dev/null 2>&1; then
        note "✔ Updated Nextcloud config.php dbpassword"
    else
        note "✘ FAILED to update Nextcloud config.php dbpassword - NOT rotating postgres role 'nextcloud', or Nextcloud would be locked out of its DB"
        return 1
    fi

    if rotate_postgres_role nextcloud nextcloud; then
        NEXTCLOUD_ROLE_OK=1
    else
        return 1
    fi

    if docker exec pi-nextcloud php occ status >/dev/null 2>&1; then
        note "✔ Verified Nextcloud can still reach its DB"
    else
        note "✘ Nextcloud DB connectivity check FAILED after dbpassword rotation - check manually"
        NEXTCLOUD_ROLE_OK=0
    fi
}

rotate_nextcloud_admin_password() {
    local username
    if ! container_is_running "pi-nextcloud"; then
        note "✘ SKIPPED Nextcloud admin password (pi-nextcloud not running)"
        return 0
    fi

    # NEXTCLOUD_ADMIN_USER only applied at first install, where it resolved to
    # $EMAIL - so that, not $ADMIN_USER, is the account that exists.
    for username in "$EMAIL" "$ADMIN_USER"; do
        [ -n "$username" ] || continue
        # -e OC_PASS by name: spelled `-e OC_PASS=<value>` the password is in the
        # host's argv for the length of the call.
        if OC_PASS="$NEW_PASSWORD" docker exec -e OC_PASS pi-nextcloud php occ user:resetpassword --password-from-env "$username" >/dev/null 2>&1; then
            note "✔ Reset Nextcloud admin password for user '$username'"
            return 0
        fi
    done
    note "✘ FAILED to reset Nextcloud admin password (tried '$EMAIL', '$ADMIN_USER') - reset manually via occ user:resetpassword"
}

# --- FreshRSS: data/config.php dbpassword + the admin account's API password ---
# Same shape as Nextcloud, and for the same reason: FreshRSS keeps its database
# password in data/config.php, written once at install, so rotating the role
# alone would lock it out for good. reconfigure.php rewrites that file, and
# update-user.php resets the password the Google Reader API checks (the web UI
# has none - it trusts REMOTE_USER from mod_auth_openidc). update-user.php needs
# the database, so it runs while the OLD role password is still valid; the gap
# between config.php and the ALTER ROLE self-heals on the next request.
#
# The new password reaches both through `docker exec -e` by name. Spelled out on
# the exec's own argv it would sit in the *host* process table; this way only the
# container's php argv carries it, and FreshRSS's CLI has no env-var or stdin
# variant to do better.

rotate_freshrss() {
    FRESHRSS_ROLE_OK=0

    if ! container_is_running "pi-freshrss"; then
        note "… SKIPPED FreshRSS (pi-freshrss not running)"
        return 0
    fi

    if FRESHRSS_NEW_PASSWORD="$NEW_PASSWORD" docker exec -e FRESHRSS_NEW_PASSWORD pi-freshrss \
        sh -c './cli/update-user.php --user "$1" --password "$FRESHRSS_NEW_PASSWORD" --api-password "$FRESHRSS_NEW_PASSWORD"' \
        _ "$ADMIN_USER" >/dev/null 2>&1; then
        note "✔ Reset the FreshRSS API password for user '$ADMIN_USER'"
    else
        note "✘ FAILED to reset the FreshRSS API password for '$ADMIN_USER' - existing feed-reader apps keep working on the old one"
    fi

    if FRESHRSS_NEW_PASSWORD="$NEW_PASSWORD" docker exec -e FRESHRSS_NEW_PASSWORD pi-freshrss \
        sh -c './cli/reconfigure.php --db-password "$FRESHRSS_NEW_PASSWORD"' >/dev/null 2>&1; then
        note "✔ Updated FreshRSS data/config.php db password"
    else
        note "✘ FAILED to update FreshRSS data/config.php - NOT rotating postgres role 'freshrss', or FreshRSS would be locked out of its DB"
        return 1
    fi

    if rotate_postgres_role freshrss freshrss; then
        FRESHRSS_ROLE_OK=1
    else
        return 1
    fi

    # The mounted healthcheck, not the image's own cli/health.php: that one
    # fetches /api/, which reads data/config.php and issues no query, so it
    # exits 0 against a database this rotation may just have locked it out of -
    # and FRESHRSS_ROLE_OK would stay 1 on a broken install. /healthcheck.sh
    # adds FreshRSS_DatabaseDAO::testConnection() (see config/freshrss).
    if docker exec pi-freshrss /healthcheck.sh >/dev/null 2>&1; then
        note "✔ Verified FreshRSS can still reach its DB"
    else
        note "✘ FreshRSS DB connectivity check FAILED after the rotation - check manually"
        FRESHRSS_ROLE_OK=0
    fi
}

# --- ntfy: regenerate the admin user hash and reload it ---

rotate_ntfy() {
    if sh "$PROJECT_DIR/scripts/ntfy-pre-start.sh" >/dev/null 2>&1; then
        note "✔ Regenerated ntfy admin credentials"
    else
        note "✘ FAILED to regenerate ntfy admin credentials"
        return 0
    fi
    recreate ntfy
}

# --- qBittorrent: live WebUI API call, no recreate needed ---
# QBITTORRENT_CREDENTIALS_OK stays "0" for every reason the rotation can fail, so
# rotate_prowlarr/rotate_kapowarr do not store a password qBittorrent itself
# never adopted.

rotate_qbittorrent() {
    local http_code
    QBITTORRENT_CREDENTIALS_OK=0

    if ! container_is_running "pi-qbittorrent"; then
        note "✘ SKIPPED qBittorrent (pi-qbittorrent not running)"
        return 1
    fi
    if [ "${#ADMIN_USER}" -lt 3 ]; then
        note "… Skipped qBittorrent (ADMIN_USER under 3-char WebUI minimum, left on default login)"
        return 1
    fi

    # The same call qbittorrent-bootstrap.sh makes on a first install.
    http_code=$(qbittorrent_set_credentials pi-qbittorrent "$ADMIN_USER" "$NEW_PASSWORD")

    if [ "$http_code" = "200" ]; then
        note "✔ Rotated qBittorrent WebUI password"
        QBITTORRENT_CREDENTIALS_OK=1
        return 0
    fi

    note "✘ FAILED to rotate qBittorrent WebUI password (HTTP $http_code)"
    return 1
}

# --- Shelfmark: PASSWORD is baked into its generated env_file ---
# It holds QBITTORRENT_PASSWORD, so the file is re-rendered and the container
# recreated - a `restart` keeps the environment compose resolved at creation
# time, which is the whole point of the recreate.
#
# Deliberately NOT gated on QBITTORRENT_CREDENTIALS_OK, unlike Prowlarr's copy.
# Prowlarr's lives in its database and nothing else rewrites it, so a gate there
# holds. Shelfmark's is re-derived from .env by shelfmark-pre-start.sh on every
# stack start, so skipping here would only defer the same write to the next
# reboot while leaving the two out of step in the meantime. When qBittorrent
# itself did not rotate, rotate_qbittorrent's own ✘ line above is the signal to
# act on.

rotate_shelfmark() {
    if ! container_is_running "pi-shelfmark"; then
        note "✘ SKIPPED Shelfmark (pi-shelfmark not running)"
        return 0
    fi
    if ! sh "$PROJECT_DIR/scripts/shelfmark-pre-start.sh" >/dev/null 2>&1; then
        note "✘ FAILED to re-render config/shelfmark/shelfmark.env"
        return 0
    fi
    note "✔ Re-rendered Shelfmark's stored qBittorrent password"
    recreate shelfmark
}

# --- Audiobookshelf: the root account's password lives in its own database ---
# scripts/audiobookshelf-bootstrap.sh creates that account once from
# ADMIN_USER/PASSWORD and never re-derives it, so without this step a rotation
# leaves it on the old value and .env claims a password nothing accepts.
#
# Local logins are off on a bootstrapped stack, which makes that password no
# longer a way in - but it is still the documented recovery path if OIDC ever
# breaks (re-enable `local` through the API, sign in with it), so keeping it in
# step with .env is what makes that path real.
#
# Authenticated with the API key the bootstrap stored, falling back to a login
# with the OLD password - by the time this runs .env already holds the new one,
# which Audiobookshelf has never seen. The key itself is unaffected by the
# change: a password update destroys session rows only.
rotate_audiobookshelf() {
    local url response token user_id

    if ! container_is_running "pi-audiobookshelf"; then
        note "✘ SKIPPED Audiobookshelf (pi-audiobookshelf not running)"
        return 0
    fi
    url="http://pi-audiobookshelf"

    token="$(audiobookshelf_api_key "$url" || true)"
    if [ -n "$token" ]; then
        user_id="$(docker_curl -H "Authorization: Bearer $token" "$url/api/me" 2>/dev/null \
            | jq -r '.id // empty')"
    else
        # Password from the environment and body on stdin, so neither the old nor
        # the new one lands in the host's process table.
        response="$(RP_OLD_PASSWORD="$OLD_PASSWORD" jq -nc --arg u "$ADMIN_USER" \
                '{username:$u, password:$ENV.RP_OLD_PASSWORD}' \
            | docker run --rm -i --network frontend "$CURL_IMAGE" $CURL_TIMEOUTS \
                -sS -X POST -H 'Content-Type: application/json' --data @- \
                "$url/login" 2>/dev/null || true)"
        token="$(printf '%s' "$response" | jq -r '.user.accessToken // empty')"
        user_id="$(printf '%s' "$response" | jq -r '.user.id // empty')"
    fi
    if [ -z "$token" ] || [ -z "$user_id" ]; then
        note "✘ FAILED to rotate Audiobookshelf (no usable API key, and no local login with the old password)"
        return 0
    fi

    if RP_NEW_PASSWORD="$NEW_PASSWORD" jq -nc '{password:$ENV.RP_NEW_PASSWORD}' \
        | docker run --rm -i --network frontend "$CURL_IMAGE" $CURL_TIMEOUTS \
            -fsS -X PATCH -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' --data @- \
            "$url/api/users/$user_id" >/dev/null 2>&1; then
        note "✔ Rotated Audiobookshelf root account password"
    else
        note "✘ FAILED to rotate Audiobookshelf password (PATCH /api/users/$user_id rejected)"
    fi
}

# --- Prowlarr: update the stored qBittorrent download-client password ---

rotate_prowlarr() {
    local key existing id updated code
    if ! container_is_running "pi-prowlarr"; then
        note "✘ SKIPPED Prowlarr (pi-prowlarr not running)"
        return 0
    fi
    if [ "$QBITTORRENT_CREDENTIALS_OK" != "1" ]; then
        note "… Skipped Prowlarr's stored qBittorrent password (qBittorrent's own WebUI login was never rotated - see above)"
        return 0
    fi

    key="$(docker exec pi-prowlarr sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n')"
    [ -n "$key" ] || { note "✘ FAILED to rotate Prowlarr download client (no API key)"; return 0; }

    existing="$(docker exec pi-prowlarr curl -sS -H "X-Api-Key: $key" "http://localhost:9696/api/v1/downloadclient" 2>/dev/null \
        | jq -c '.[]? | select(.name=="qBittorrent")' 2>/dev/null)"
    [ -n "$existing" ] && [ "$existing" != "null" ] || { note "… Skipped Prowlarr (no qBittorrent download client registered)"; return 0; }

    id="$(printf '%s' "$existing" | jq -r '.id')"
    # Through the environment, not --arg: jq's argv is in the host's process
    # table for the length of the call.
    updated="$(printf '%s' "$existing" | RP_NEW_PASSWORD="$NEW_PASSWORD" jq -c \
        '.fields = ([.fields[] | if .name=="password" then .value=$ENV.RP_NEW_PASSWORD else . end])')"
    code="$(printf '%s' "$updated" | docker exec -i pi-prowlarr curl -sS -o /dev/null -w '%{http_code}' \
        -X PUT -H "X-Api-Key: $key" -H "Content-Type: application/json" \
        --data @- "http://localhost:9696/api/v1/downloadclient/$id")"

    case "$code" in
        20*) note "✔ Rotated Prowlarr qBittorrent download client password" ;;
        *)   note "✘ FAILED to rotate Prowlarr download client password (HTTP $code)" ;;
    esac
}

# --- Kapowarr: update the stored qBittorrent external client password ---

rotate_kapowarr() {
    local out
    if ! container_is_running "pi-kapowarr"; then
        note "✘ SKIPPED Kapowarr (pi-kapowarr not running)"
        return 0
    fi
    if [ "$QBITTORRENT_CREDENTIALS_OK" != "1" ]; then
        note "… Skipped Kapowarr's stored qBittorrent password (qBittorrent's own WebUI login was never rotated - see above)"
        return 0
    fi

    out="$(KAP_USER="$ADMIN_USER" KAP_PASS="$NEW_PASSWORD" docker exec -i \
        -e KAP_USER -e KAP_PASS pi-kapowarr python3 - <<'PY' 2>&1
import json, os, urllib.parse, urllib.request

BASE = "http://localhost:5656/api"
USER = os.environ.get("KAP_USER") or None
PASS = os.environ.get("KAP_PASS") or None


def call(method, path, params=None, body=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                  headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.loads(r.read() or b"{}")


_, res = call("POST", "/auth", body={"username": USER, "password": PASS})
key = (res.get("result") or {}).get("api_key")
if not key:
    raise SystemExit("no api_key")

_, res = call("GET", "/externalclients", params={"api_key": key})
clients = res.get("result") or []
existing = next((c for c in clients if c.get("title") == "qBittorrent"), None)
if existing is None:
    raise SystemExit("no qBittorrent external client registered")

body = {
    "title": "qBittorrent",
    "base_url": existing.get("base_url"),
    "username": USER,
    "password": PASS,
    "api_token": None,
}
call("PUT", f"/externalclients/{existing['id']}", params={"api_key": key}, body=body)
print("rotated")
PY
)"

    if printf '%s\n' "$out" | grep -q '^rotated$'; then
        note "✔ Rotated Kapowarr qBittorrent external client password"
    else
        note "✘ FAILED to rotate Kapowarr external client password ($(printf '%s\n' "$out" | tail -n1))"
    fi
}

# --- Dockhand: authenticate with the OLD password, then update it ---

rotate_dockhand() {
    local url usernames candidate cookie users_json user_id response status
    # Dockhand sits alone with Traefik on `dockhand`. Scoped to this function:
    # every other target in this file is still on frontend.
    local DOCKER_CURL_NETWORK="dockhand"

    if ! container_is_running "pi-dockhand"; then
        note "✘ SKIPPED Dockhand (pi-dockhand not running)"
        return 0
    fi
    url="http://pi-dockhand:3000"
    usernames="$(build_candidate_usernames "$ADMIN_USER" "$EMAIL")"

    cookie=""
    for candidate in $usernames; do
        # Both hops keep the password out of a process table: the environment
        # rather than jq's --arg, and stdin rather than `docker run ... -d`.
        # -i so the container can read the body; -f is deliberately absent
        # because a 401 here is an expected answer, not a failure.
        response="$(RP_OLD_PASSWORD="$OLD_PASSWORD" jq -nc --arg u "$candidate" \
                '{username:$u,password:$ENV.RP_OLD_PASSWORD,provider:"local"}' \
            | docker run --rm -i --network "$DOCKER_CURL_NETWORK" "$CURL_IMAGE" $CURL_TIMEOUTS \
                -sS -i -X POST -H 'Content-Type: application/json' --data @- \
                "$url/api/auth/login" 2>/dev/null || true)"
        status="$(printf '%s' "$response" | awk 'NR==1 {print $2}')"
        cookie="$(printf '%s' "$response" | awk 'tolower($0) ~ /^set-cookie:/ {sub(/^[^:]*:[[:space:]]*/, "", $0); split($0, a, ";"); print a[1]; exit}' | tr -d '\r\n')"
        [ "$status" = "200" ] && [ -n "$cookie" ] && break
        cookie=""
    done
    [ -n "$cookie" ] || { note "✘ FAILED to rotate Dockhand admin password (could not authenticate with old password)"; return 0; }

    users_json="$(api_get_with_cookie "$url" "/api/users" "$cookie")"
    user_id="$(printf '%s' "$users_json" | jq -r --arg u "$candidate" '[.[] | select(.username==$u)] | first | .id // empty')"
    [ -n "$user_id" ] || { note "✘ FAILED to rotate Dockhand admin password (could not find user id for '$candidate')"; return 0; }

    if RP_NEW_PASSWORD="$NEW_PASSWORD" jq -nc '{password:$ENV.RP_NEW_PASSWORD}' \
        | api_send_json_stdin PUT "$url" "/api/users/$user_id" "$cookie" >/dev/null 2>&1; then
        note "✔ Rotated Dockhand password for local user '$candidate'"
    else
        note "✘ FAILED to rotate Dockhand admin password (PUT /api/users/$user_id rejected)"
    fi
}

# --- Beszel: best-effort PocketBase superuser reset ---
# DISABLE_PASSWORD_AUTH=true means this account is a break-glass credential
# (normal login goes through Authelia OIDC), so a failure here is low-impact.

rotate_beszel_superuser() {
    if ! container_is_running "pi-beszel"; then
        note "✘ SKIPPED Beszel (pi-beszel not running)"
        return 0
    fi
    [ -n "$EMAIL" ] || { note "✘ SKIPPED Beszel superuser (EMAIL not set)"; return 0; }

    # The beszel CLI takes the password as a positional argument only - no stdin
    # or env form exists - so this one call unavoidably puts it in argv.
    if docker exec pi-beszel /beszel superuser upsert "$EMAIL" "$NEW_PASSWORD" >/dev/null 2>&1; then
        note "✔ Rotated Beszel superuser password (break-glass only, DISABLE_PASSWORD_AUTH is on)"
    else
        note "… Beszel superuser reset unavailable via CLI - low impact, login is via OIDC (DISABLE_PASSWORD_AUTH=true)"
    fi
}

main() {
    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    OLD_PASSWORD="$(get_env_value PASSWORD)"
    ADMIN_USER="$(get_env_value ADMIN_USER)"
    EMAIL="$(get_env_value EMAIL)"
    [ -n "$OLD_PASSWORD" ] || die "PASSWORD is not set in .env"

    confirm

    NEW_PASSWORD="$(generate_secret)"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

    # Never echoed to stdout or the logs (AGENTS.md: never print secrets); the
    # summary prints this path instead.
    RESULT_FILE="$PROJECT_DIR/.rotate-password.new-password.$TIMESTAMP"
    if ! write_secret_file "$RESULT_FILE" "$NEW_PASSWORD"; then
        die "Could not write $RESULT_FILE to record the new password - aborting before making any change"
    fi

    if [ "$SKIP_POSTGRES" = "1" ]; then
        log "=== --skip-postgres: .env is not touched (see file header for why) ==="
    else
        BACKUP_FILE="$ENV_FILE.bak.$TIMESTAMP"
        if ! cp "$ENV_FILE" "$BACKUP_FILE"; then
            die "Could not back up .env to $BACKUP_FILE - aborting before touching .env"
        fi
        log "Backed up .env to $BACKUP_FILE"

        log "=== Writing new PASSWORD to .env ==="
        if ! grep -q '^PASSWORD=' "$ENV_FILE"; then
            die "PASSWORD= line not found in .env; restore from $BACKUP_FILE and check manually"
        fi
        if sed -i "s|^PASSWORD=.*|PASSWORD=$(sed_escape "$NEW_PASSWORD")|" "$ENV_FILE" && [ "$(get_env_value PASSWORD)" = "$NEW_PASSWORD" ]; then
            note "✔ Updated PASSWORD in .env"
        else
            die "Failed to update PASSWORD in .env (or the write didn't verify) - restore from $BACKUP_FILE and check manually"
        fi
    fi

    log "=== LLDAP admin account (the SSO master credential) ==="
    rotate_lldap_admin_password

    log "=== Authelia ldap_password (independent of Postgres - see file header) ==="
    rotate_authelia_ldap_secret

    if [ "$SKIP_POSTGRES" = "1" ]; then
        log "=== --skip-postgres set: stopping here ==="
    else
        log "=== Nextcloud (pre-rotation: needs the OLD password still valid) ==="
        rotate_nextcloud_db_password
        rotate_nextcloud_admin_password

        log "=== FreshRSS (data/config.php + API password, then its role) ==="
        rotate_freshrss

        log "=== Remaining Postgres roles ==="
        rotate_postgres_roles

        log "=== Authelia db_password (gated on the authelia role above) ==="
        rotate_authelia_db_secret

        log "=== Recreating containers that bake PASSWORD into their environment ==="
        # Gated per role: a container whose role failed to rotate is left running
        # on its current, still-consistent env rather than recreated into a crash
        # loop against a password Postgres does not have.
        if [ "$LLDAP_ROLE_OK" = "1" ]; then recreate lldap; else note "… Skipped recreating lldap - its Postgres role didn't rotate"; fi
        if [ "$OPEN_WEBUI_ROLE_OK" = "1" ]; then recreate open-webui; else note "… Skipped recreating open-webui - its Postgres role didn't rotate"; fi
        if [ "$IMMICH_ROLE_OK" = "1" ]; then recreate immich-server pi-immich; else note "… Skipped recreating immich-server - its Postgres role didn't rotate"; fi
        if [ "$NEXTCLOUD_ROLE_OK" = "1" ]; then recreate nextcloud; else note "… Skipped recreating nextcloud - its Postgres role/dbpassword didn't rotate cleanly"; fi
        # Vaultwarden reads DATABASE_URL from env, so the recreate is what actually
        # applies the new role password. Its ADMIN_TOKEN is independent of PASSWORD
        # and deliberately untouched here - see scripts/vaultwarden-pre-start.sh.
        if [ "$VAULTWARDEN_ROLE_OK" = "1" ]; then recreate vaultwarden; else note "… Skipped recreating vaultwarden - its Postgres role didn't rotate"; fi
        # agentgateway holds no Postgres role and reads no PASSWORD: its state is
        # SQLite, and its cookie secret and LLM API key are generated files this
        # deliberately never touches - see scripts/agentgateway-pre-start.sh.
        # backrest is NOT gated on the roles, unlike the containers above.
        # Its UI login is no longer PASSWORD - that lives in
        # config/backrest/backrest.env and is untouched by a rotation - so the
        # only thing the recreate carries is the five *_DB_PASSWORD values its
        # snapshot hooks use for pg_dump. The gate would not buy consistency
        # anyway: backrest bundles all five roles into one environment, so after
        # a partial rotation *some* dump password is wrong either way.
        # Recreating makes the rotated majority work; skipping breaks them
        # instead. backrest touches Postgres only from its snapshot hooks, so
        # there is no crash loop to avoid here.
        recreate backrest
        _stale_dumps=""
        [ "$NEXTCLOUD_ROLE_OK" = "1" ]   || _stale_dumps="$_stale_dumps nextcloud"
        [ "$AUTHELIA_ROLE_OK" = "1" ]    || _stale_dumps="$_stale_dumps authelia"
        [ "$LLDAP_ROLE_OK" = "1" ]       || _stale_dumps="$_stale_dumps lldap"
        [ "$OPEN_WEBUI_ROLE_OK" = "1" ]  || _stale_dumps="$_stale_dumps open-webui"
        [ "$VAULTWARDEN_ROLE_OK" = "1" ] || _stale_dumps="$_stale_dumps vaultwarden"
        [ "$IMMICH_ROLE_OK" = "1" ]      || _stale_dumps="$_stale_dumps immich"
        [ "$FRESHRSS_ROLE_OK" = "1" ]    || _stale_dumps="$_stale_dumps freshrss"
        if [ -n "$_stale_dumps" ]; then
            note "⚠ backrest now holds the new PASSWORD, but these roles did not rotate:$_stale_dumps"
            note "  Their db-backup.sh dumps will fail until the role is fixed. nextcloud and"
            note "  vaultwarden are ON_ERROR_FATAL hooks, so a failure there aborts the snapshot."
        fi
        recreate pihole
        recreate beszel
        recreate homepage
        rotate_ntfy

        log "=== Live API credential updates (no recreate needed) ==="
        rotate_qbittorrent
        rotate_shelfmark
        rotate_prowlarr
        rotate_kapowarr
        rotate_audiobookshelf
        rotate_dockhand
        rotate_beszel_superuser
    fi

    echo ""
    echo "=== Rotation summary ==="
    printf '%s' "$SUMMARY"
    echo ""
    if [ "$SKIP_POSTGRES" = "1" ]; then
        echo "PASSWORD in .env was left UNCHANGED on purpose (--skip-postgres) - it no"
        echo "longer matches the LLDAP admin/Authelia bind password, which is intentional."
    else
        echo "New PASSWORD saved in .env."
        echo ".env backup: $BACKUP_FILE"
    fi
    echo "New password recorded at: $RESULT_FILE (chmod 600) - read it, then delete it:"
    echo "  cat $RESULT_FILE && rm -f $RESULT_FILE"
    echo ""
    echo "Review any '✘ FAILED' lines above and fix those services manually."
}

main "$@"
