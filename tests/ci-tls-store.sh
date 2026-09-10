#!/bin/sh
# A certificate CI's own containers trust, handed to Traefik the way ACME
# would have.
#
# Two services fetch Authelia's OIDC discovery document over TLS *at startup*
# and exit when it fails: headscale (only_start_if_oidc_is_available: true,
# deliberately) and agentgateway (ui.policies.oidc). On a runner the ACME
# resolver holds a placeholder Cloudflare token and can issue nothing, so
# Traefik answers with its own generated certificate, verification fails, and
# both were parked in compose.test.yaml's ci-excluded list for it.
#
# The fix has to give Traefik a certificate without touching compose.yaml.
# That rules out the file provider, which is where a `defaultCertificate`
# normally lives: Traefik treats CLI flags, environment and file as mutually
# exclusive static-configuration sources, and compose.yaml configures it
# entirely with flags - measured, not assumed. With those flags in place a
# TRAEFIK_PROVIDERS_FILE_FILENAME in the environment leaves `providers` empty
# in the loaded static configuration.
#
# So the certificate goes in through the one door already open: the ACME
# store. compose.yaml mounts ${DATA_LOCATION}/traefik/letsencrypt at
# /letsencrypt, and a store that already holds a certificate covering a domain
# is a domain Traefik never asks the CA for. Nothing in compose.yaml changes,
# and CI exercises the real certificate-serving path rather than a CI-only one.
#
# Usage: ci-tls-store.sh <letsencrypt-dir> <ca-dir>
#   <letsencrypt-dir>/acme.json  the store, 0600 - Traefik refuses it wider
#   <ca-dir>/ca-cert.pem         the root, 0644 - mounted into the two
#                                containers above and named by SSL_CERT_FILE
#
# It refuses to run when the store already exists, which is what stops it
# being pointed at a real install: there, acme.json holds the certificates
# Let's Encrypt issued, and reissuing them costs a duplicate-certificate rate
# limit. CI wipes DATA_LOCATION before every run, so the guard never fires
# there. CI_TLS_FORCE=1 overrides it for a dirty scratch directory.
set -eu

STORE_DIR="${1:?usage: $(basename "$0") <letsencrypt-dir> <ca-dir>}"
CA_DIR="${2:?usage: $(basename "$0") <letsencrypt-dir> <ca-dir>}"

# Must match --certificatesresolvers.<name>.acme.* in compose.yaml: the store
# is keyed by resolver name, and a certificate filed under any other key is
# one Traefik never looks at.
RESOLVER="${CI_TLS_RESOLVER:-cloudflare}"
DOMAIN="${HOST_NAME:-test.local}"
EMAIL="${EMAIL:-test@example.com}"

# Long enough that Traefik never tries to renew it. It renews at a third of
# certificatesDuration remaining, 30 days by default, and a renewal here would
# mean a real ACME call to Let's Encrypt with a placeholder token on every
# pull request. A CI job lives for minutes, so the only thing this number
# controls is whether that call happens.
DAYS="${CI_TLS_DAYS:-120}"

# Before anything is generated, and before the directories are created: the
# whole point is to not have written to a real store by the time we find out.
if [ -e "$STORE_DIR/acme.json" ] && [ "${CI_TLS_FORCE:-0}" != 1 ]; then
    printf '%s: %s already exists.\n' "$(basename "$0")" "$STORE_DIR/acme.json" >&2
    printf 'This script overwrites it, and on a real host that file is the only copy of\n' >&2
    printf "the certificates Let's Encrypt issued. If this really is a scratch directory,\n" >&2
    printf 'delete it or re-run with CI_TLS_FORCE=1.\n' >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

mkdir -p "$STORE_DIR" "$CA_DIR"

# A real two-certificate chain, not a self-signed leaf doubling as its own
# root: Go's verifier wants a parent with basicConstraints CA:true, and the
# rules for when it will accept a leaf out of the root pool are subtle enough
# that issuing properly is the shorter path.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/ca-key.pem" -out "$WORK/ca-cert.pem" -days "$DAYS" \
    -subj "/CN=pi-pcloud CI CA" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
    -keyout "$WORK/leaf-key.pem" -out "$WORK/leaf.csr" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1

# Both the apex and the wildcard, which is what the routers ask for: the
# traefik and headscale routers name them explicitly in tls.domains, and every
# other host in the stack is one label deep so the wildcard covers it.
cat > "$WORK/leaf.ext" <<EXT
subjectAltName = DNS:${DOMAIN}, DNS:*.${DOMAIN}
extendedKeyUsage = serverAuth
basicConstraints = critical,CA:false
EXT

openssl x509 -req -in "$WORK/leaf.csr" \
    -CA "$WORK/ca-cert.pem" -CAkey "$WORK/ca-key.pem" -CAcreateserial \
    -out "$WORK/leaf-cert.pem" -days "$DAYS" -extfile "$WORK/leaf.ext" >/dev/null 2>&1

# The ACME account. Traefik parses this with x509.ParsePKCS1PrivateKey, so it
# has to be traditional DER rather than the PKCS#8 openssl 3 writes by
# default. Never used - no domain is left for the resolver to order - but an
# account it cannot parse is an error at startup.
openssl genrsa -traditional 2048 2>/dev/null > "$WORK/acct-key.pem"
openssl rsa -in "$WORK/acct-key.pem" -traditional -outform DER \
    -out "$WORK/acct-key.der" >/dev/null 2>&1

CI_TLS_WORK="$WORK" CI_TLS_RESOLVER="$RESOLVER" CI_TLS_DOMAIN="$DOMAIN" \
CI_TLS_EMAIL="$EMAIL" CI_TLS_STORE="$STORE_DIR/acme.json" python3 - <<'PY'
import base64, json, os, pathlib

work = pathlib.Path(os.environ["CI_TLS_WORK"])
domain = os.environ["CI_TLS_DOMAIN"]


def b64(name):
    return base64.b64encode((work / name).read_bytes()).decode()


# Field names are Traefik's own: types.Certificate tags domain/certificate/key
# in lower case, everything around it keeps the Go field name. A key it does
# not recognise is silently dropped, which would look like an empty store.
store = {
    os.environ["CI_TLS_RESOLVER"]: {
        "Account": {
            "Email": os.environ["CI_TLS_EMAIL"],
            "Registration": {
                "body": {"status": "valid"},
                "uri": "https://acme.invalid/acct/1",
            },
            "PrivateKey": b64("acct-key.der"),
            "KeyType": "2048",
        },
        "Certificates": [
            {
                "domain": {"main": domain, "sans": [f"*.{domain}"]},
                "certificate": b64("leaf-cert.pem"),
                "key": b64("leaf-key.pem"),
                "Store": "default",
            }
        ],
    }
}

pathlib.Path(os.environ["CI_TLS_STORE"]).write_text(json.dumps(store))
PY

chmod 600 "$STORE_DIR/acme.json"

cp "$WORK/ca-cert.pem" "$CA_DIR/ca-cert.pem"
# World-readable on purpose: agentgateway runs as uid 1000 and headscale as
# root, and this is a root certificate whose private key was in a temporary
# directory this script has already deleted.
chmod 644 "$CA_DIR/ca-cert.pem"

printf '%s: %s and %s issued for %s, valid %s days\n' \
    "$(basename "$0")" "$STORE_DIR/acme.json" "$CA_DIR/ca-cert.pem" \
    "${DOMAIN} and *.${DOMAIN}" "$DAYS"
