#!/bin/sh
# Mount the qBittorrent downloads folder and the reading libraries as external
# storage so any file (not just photos, unlike Immich) can get a public Nextcloud
# share link. Restricted to the "admin" group.
# This runs once, right after a fresh Nextcloud installation. It is idempotent, so
# on an existing install it can be re-run by hand:
#   docker exec -u www-data pi-nextcloud sh /docker-entrypoint-hooks.d/post-installation/20-external-storage.sh
#
# Never exits non-zero: the nextcloud image's entrypoint aborts the container
# when a post-installation hook fails, and these hooks are never re-run (the
# version stamp lands before they do) — so a failure here would leave a fresh
# install permanently unable to start over a convenience mount. set -u only;
# every step is checked explicitly and failure logs a warning and exits 0.

set -u

OCC="php /var/www/html/occ"
MOUNT_GROUP="admin"
# "<mount point>:<path inside this container>". The paths are read-only bind mounts
# declared on the nextcloud service in compose/compose-cloud.yaml; keep the two lists in step.
MOUNTS="Downloads:/mnt/qbittorrent-downloads
Comics:/mnt/library-comics
Manga:/mnt/library-manga
Books:/mnt/library-books
Audiobooks:/mnt/library-audiobooks"

# Never fatal, and never aborts the remaining mounts: one missing bind mount must not
# cost the others. Callers treat a non-zero return as "this mount was skipped".
warn_and_skip() {
  echo "WARNING: $* — skipping this external storage mount" >&2
  return 1
}

warn_and_exit() {
  echo "WARNING: $* — skipping external storage setup (re-run this hook manually via docker exec)" >&2
  exit 0
}

$OCC app:enable files_external || warn_and_exit "could not enable files_external"

# The mount id for $MOUNT_NAME, or empty. Parsed with php (jq is not in this
# image); any warning noise occ prints before the JSON array is stripped by
# seeking to the first '['. An existence-only check could not repair a
# half-created mount, which is why the id is resolved rather than grepped.
existing_mount_id() {
  $OCC files_external:list --output=json 2>/dev/null | php -r '
    $in = stream_get_contents(STDIN);
    $start = strpos($in, "[");
    $rows = $start === false ? null : json_decode(substr($in, $start), true);
    if (!is_array($rows)) { exit(0); }
    foreach ($rows as $row) {
        if (ltrim($row["mount_point"] ?? "", "/") === $argv[1]) {
            echo $row["mount_id"] ?? "";
            exit(0);
        }
    }
  ' -- "$1"
}

configure_mount() {
  local_name="$1"
  local_path="$2"
  CREATED=""

  [ -d "$local_path" ] || warn_and_skip "$local_path not mounted into this container" || return 1

  MOUNT_ID="$(existing_mount_id "$local_name")"
  if [ -n "$MOUNT_ID" ]; then
    echo "External storage '$local_name' already exists (id $MOUNT_ID), reconciling"
  else
    # With the default plain output this prints "Storage created with id N",
    # not a bare number — only the trailing integer is the id.
    CREATED="$($OCC files_external:create "$local_name" local null::null \
      -c datadir="$local_path")" || warn_and_skip "files_external:create failed for '$local_name'" || return 1
    MOUNT_ID="$(printf '%s' "$CREATED" | grep -oE '[0-9]+' | tail -n1)"
    # A create that printed no id: fall back to re-resolving from the list.
    [ -n "$MOUNT_ID" ] || MOUNT_ID="$(existing_mount_id "$local_name")"
  fi

  case "$MOUNT_ID" in
    ''|*[!0-9]*)
      warn_and_skip "could not determine the mount id for '$local_name' (create printed: '$CREATED')" || return 1
      ;;
  esac

  # All three are idempotent, so they also repair a mount left half-configured by an
  # earlier failed run.
  $OCC files_external:applicable "$MOUNT_ID" --add-group="$MOUNT_GROUP" \
    || warn_and_skip "files_external:applicable failed for mount $MOUNT_ID" || return 1
  $OCC files_external:option "$MOUNT_ID" enable_sharing true \
    || warn_and_skip "enable_sharing failed for mount $MOUNT_ID" || return 1
  # files_external:create leaves this unset, so the mount inherits the system value
  # (0 = never re-stat) and files written after the first scan stay invisible. The
  # system value cannot fix it — it excludes external storage — so it has to be set
  # per mount, as the web UI does.
  $OCC files_external:option "$MOUNT_ID" filesystem_check_changes 1 \
    || warn_and_skip "filesystem_check_changes failed for mount $MOUNT_ID" || return 1

  echo "External storage '$local_name' (id $MOUNT_ID) -> $local_path, group '$MOUNT_GROUP', sharing on, change detection on"
}

# IFS newline so a mount point may contain spaces; the path never does.
OLD_IFS="$IFS"
IFS='
'
for entry in $MOUNTS; do
  IFS="$OLD_IFS"
  configure_mount "${entry%%:*}" "${entry#*:}" || true
  IFS='
'
done
IFS="$OLD_IFS"
