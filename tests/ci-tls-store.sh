#!/bin/sh
# A certificate CI's own containers trust, handed to Traefik the way ACME
# would have.
#
# headscale and agentgateway fetch Authelia's OIDC discovery document over TLS
# at startup and exit when it fails, and CI's ACME resolver holds a
# placeholder token, so Traefik served its own generated certificate.
#
# The certificate has to reach Traefik without touching compose.yaml, which
# rules out the file provider where a `defaultCertificate` normally lives:
# Traefik takes CLI flags, environment and file as mutually exclusive static
# configuration sources, and compose.yaml uses flags. Measured - with them in
# place, TRAEFIK_PROVIDERS_FILE_FILENAME leaves `providers` empty.
#
# So it goes in through the ACME store compose.yaml already mounts at
# /letsencrypt: a domain the store covers is one Traefik never asks the CA
# for, and it serves the leaf through its normal path.
#
# Usage: ci-tls-store.sh <letsencrypt-dir> <ca-dir>
#   <letsencrypt-dir>/acme.json  the store, 0600 - Traefik refuses it wider
#   <ca-dir>/ca-cert.pem         the root, 0644 - named by SSL_CERT_FILE
#
# Refuses to run when the store already exists, so it cannot be pointed at a
# real install's certificates; CI_TLS_FORCE=1 overrides. CI wipes
# DATA_LOCATION every run, so the guard never fires there.
set -eu

STORE_DIR="${1:?usage: $(basename "$0") <letsencrypt-dir> <ca-dir>}"
CA_DIR="${2:?usage: $(basename "$0") <letsencrypt-dir> <ca-dir>}"

# Must match --certificatesresolvers.<name>.acme.* in compose.yaml: the store
# is keyed by resolver name, and a certificate filed under any other key is
# one Traefik never looks at.
RESOLVER="${CI_TLS_RESOLVER:-cloudflare}"
DOMAIN="${HOST_NAME:-test.local}"
EMAIL="${EMAIL:-test@example.com}"

# Long enough that Traefik never renews: it renews at a third of
# certificatesDuration remaining, 30 days by default, and a renewal here means
# a real Let's Encrypt call with a placeholder token on every pull request.
DAYS="${CI_TLS_DAYS:-120}"

# Before anything is generated or any directory created.
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

# A real chain rather than a self-signed leaf in the root pool: Go's verifier
# wants a parent with basicConstraints CA:true, and issuing properly is the
# shorter path than working out when it accepts a leaf as its own root.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/ca-key.pem" -out "$WORK/ca-cert.pem" -days "$DAYS" \
    -subj "/CN=pi-pcloud CI CA" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
    -keyout "$WORK/leaf-key.pem" -out "$WORK/leaf.csr" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1

# Apex and wildcard: the traefik and headscale routers name both in
# tls.domains, and every other host is one label deep.
cat > "$WORK/leaf.ext" <<EXT
subjectAltName = DNS:${DOMAIN}, DNS:*.${DOMAIN}
extendedKeyUsage = serverAuth
basicConstraints = critical,CA:false
EXT

openssl x509 -req -in "$WORK/leaf.csr" \
    -CA "$WORK/ca-cert.pem" -CAkey "$WORK/ca-key.pem" -CAcreateserial \
    -out "$WORK/leaf-cert.pem" -days "$DAYS" -extfile "$WORK/leaf.ext" >/dev/null 2>&1

# The ACME account. Never used, since no domain is left to order, but one
# Traefik cannot parse is an error at startup - and it uses
# x509.ParsePKCS1PrivateKey, so traditional DER, not openssl 3's PKCS#8.
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


# Field names are Traefik's own - types.Certificate tags
# domain/certificate/key lower case, the rest keep their Go names. An
# unrecognised key is dropped silently, which looks like an empty store.
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
# World-readable on purpose: agentgateway runs as uid 1000, headscale as root,
# and this is a public certificate - its key was in $WORK, already gone.
chmod 644 "$CA_DIR/ca-cert.pem"

printf '%s: %s and %s issued for %s, valid %s days\n' \
    "$(basename "$0")" "$STORE_DIR/acme.json" "$CA_DIR/ca-cert.pem" \
    "${DOMAIN} and *.${DOMAIN}" "$DAYS"
