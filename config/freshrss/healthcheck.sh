#!/bin/sh
# Container healthcheck for FreshRSS, mounted read-only at /healthcheck.sh.
#
# Two probes, because either alone is blind:
#
#   cli/health.php  fetches http://localhost/api/ and so proves Apache, PHP and
#                   the vhost are serving. It is NOT a database check:
#                   p/api/index.php only calls FreshRSS_Context::initSystem(),
#                   which reads data/config.php off disk. Measured with the
#                   container cut off from the `rss` network, it still exits 0
#                   while every page under /i/ is a 500.
#   the PHP below   runs FreshRSS's own FreshRSS_DatabaseDAO::testConnection()
#                   (a SELECT 1 over the credentials in data/config.php), which
#                   is the half a reader actually notices. ~60 ms, and it
#                   writes nothing under data/.
#
# Mounted from config/freshrss. It must not source scripts/lib.sh: that file
# does not exist inside this container, and this one is not a host script.
set -eu

cd /var/www/FreshRSS

./cli/health.php

# Minz_User::INTERNAL_USER ("_") rather than the admin account: a PDO handle is
# opened per user, and the probe must not depend on which usernames exist.
# The try/catch is load-bearing - an unresolvable `postgres` throws out of the
# Minz_ModelPdo constructor before testConnection() is reached, and an uncaught
# Throwable exits 255 with a stack trace in the healthcheck output.
exec php -r '
try {
    require "/var/www/FreshRSS/constants.php";
    require LIB_PATH . "/lib_rss.php";
    FreshRSS_Context::initSystem();
    $err = (new FreshRSS_DatabaseDAO(Minz_User::INTERNAL_USER))->testConnection();
} catch (Throwable $e) {
    $err = $e->getMessage();
}
if ($err !== "") {
    fwrite(STDERR, "FreshRSS cannot reach its database: " . $err . PHP_EOL);
    exit(1);
}
'
