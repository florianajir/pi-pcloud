#!/bin/sh
# Post-start: switch FreshRSS's WebSub (PubSubHubbub) off.
#
# The installer turns it on whenever the base URL is a public name, but
# rss.<HOST_NAME> sits behind lan@docker, so no hub can reach the callback:
# every subscription fails, after handing the hub that URL. Feeds are polled by
# the image's cron (CRON_MIN) either way. No CLI option reaches this setting,
# hence the PHP, which saves only when the value is still on.
#
# Run as www-data under umask 027: save() writes a new config.php and renames it
# over the old one, and that file holds the database password.
#
# A post-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

CONTAINER=pi-freshrss

wait_for_container "$CONTAINER" 60 2

# shellcheck disable=SC2016 # PHP variables, expanded by php, not the shell
result="$(docker exec -u www-data "$CONTAINER" sh -c 'umask 027 && php -r '\''
require "/var/www/FreshRSS/cli/_cli.php";
$conf = FreshRSS_Context::systemConf();
if (!$conf->pubsubhubbub_enabled) {
    echo "unchanged";
    exit(0);
}
$conf->pubsubhubbub_enabled = false;
echo $conf->save() ? "disabled" : "failed";
'\''')" || die "FreshRSS: could not read its system configuration"

case "$result" in
    unchanged) log "FreshRSS: WebSub already off" ;;
    disabled) log "FreshRSS: WebSub switched off" ;;
    *) die "FreshRSS: could not save config.php ($result)" ;;
esac
