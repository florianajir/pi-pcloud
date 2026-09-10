FROM ghcr.io/garethgeorge/backrest:v1.14.1
# postgresql-client is a virtual package, so the pin names its concrete provider.
# The client major MUST match the stack's Postgres server major (compose.yaml
# pins immich-app/postgres:18): a newer pg_dump emits SET parameters the older
# server does not know (e.g. transaction_timeout, added in 17), and the restore
# then aborts on its very first line under ON_ERROR_STOP. Verified in a restore
# drill against a real dump. Bump this together with the server image.
# Pinned to the generation, here and on every apk line below. The
# reproducibility boundary is the base image's Alpine branch, and inside 3.24 a
# package only moves for a patch — an exact pin bought little and cost a build
# (jq went 1.8.1-r0 -> 1.8.2-r0 unnoticed until CI rebuilt this). Still a real
# bound: `=~18` refuses 17 or 19, and `=~1.7` fails against today's jq.
# postgresql18-client lives in main, unlike the 16 client which was in community.
RUN apk add --no-cache postgresql18-client=~18 jq=~1
# apache2-utils provides htpasswd, the only bcrypt tool available here; the
# auth entrypoint needs it to turn BACKREST_AUTH_PASSWORD into config.json's
# user. The host has no bcrypt tool, so this cannot happen in pre-start.
# scripts/ntfy-pre-start.sh borrows the same htpasswd to *verify* a stored hash
# rather than re-generating one on every start.
RUN apk add --no-cache apache2-utils=~2.4
# openldap-clients gives scripts/rotate-password.sh ldappasswd/ldapwhoami. Baked
# rather than pulled at run time: fetching a package mid-rotation is the worst
# time to fail, and the image the stack already builds is always on disk.
RUN apk add --no-cache openldap-clients=~2.6
# sqlite gives scripts/sqlite-backup.sh the `.backup` command, the only way to
# get a consistent copy of a live WAL-mode database. restic copying the .db and
# its -wal at different instants cannot.
RUN apk add --no-cache sqlite=~3
COPY auth-entrypoint.sh /usr/local/bin/auth-entrypoint.sh
# Keep the base image's tini + /docker-entrypoint chain; only prepend the hook.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/auth-entrypoint.sh"]
CMD ["/backrest"]
