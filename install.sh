#!/bin/sh
# pi-pcloud quick-start installer:
#   curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
#
# Checks prerequisites, clones the repository (default ~/pi-pcloud, override
# with PI_PCLOUD_DIR; run from inside an existing clone to reuse it), builds
# .env from .env.dist by prompting for the Makefile's REQUIRED_ENV_VARS, then
# hands over to `make preflight` and `make install`.
#
# Standalone by design: the prerequisite/clone phase runs before the clone
# exists, so it cannot source scripts/lib.sh. Post-clone helpers delegate to
# lib.sh in a subshell (sourcing it here would clobber this script's log/die).
#
# Safe to re-run: an existing clone is fast-forwarded, an existing .env is
# never touched, and .env only appears once fully configured. Prompts use
# whiptail dialogs when it is installed and a terminal is present, and fall
# back to plain prompts otherwise; both read from /dev/tty (stdin is the
# script itself when piped from curl). Any value already exported skips its
# prompt or overrides its auto-detection, which allows unattended installs
# (these need passwordless sudo, as `make install` applies sysctl/systemd
# changes).
set -eu

REPO_URL="${PI_PCLOUD_REPO:-https://github.com/florianajir/pi-pcloud.git}"
# Privilege prefix for the handful of root-only commands below; check_privileges
# empties it when the installer already runs as root, since a root-only image
# often ships without a sudo binary at all. The Makefile applies the same rule
# to its own recipes, so `make install` works in that environment too.
SUDO="sudo"

log() { printf '[pi-pcloud] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
# `true`, not `:` — a redirection error on a special builtin like `:` is fatal
# in dash (the script aborts instead of returning a failure status).
interactive() { { true </dev/tty; } 2>/dev/null; }

# Dialog prompts, used whenever whiptail and a terminal are both available;
# every caller keeps the plain-prompt fallback so minimal hosts install the
# same. whiptail draws its UI on stdout, so the UI is pinned to /dev/tty and
# the answer travels over fd 3 (--output-fd), leaving command substitution
# free for the result. A cancelled dialog (Esc/Cancel) returns non-zero; the
# callers map that to an empty answer and re-prompt — Ctrl+C stays the only
# way to abort, so a stray Esc cannot discard the answers already given.
WHIPTAIL_TITLE="pi-pcloud installer"
use_whiptail() { have whiptail && interactive; }

ui_yesno() {
    whiptail --title "$WHIPTAIL_TITLE" --defaultno --yesno "$1" 10 72 \
        </dev/tty >/dev/tty
}

ui_inputbox() {
    whiptail --title "$WHIPTAIL_TITLE" --inputbox "$1" 10 72 "$2" \
        --output-fd 3 3>&1 </dev/tty >/dev/tty
}

ui_passwordbox() {
    whiptail --title "$WHIPTAIL_TITLE" --passwordbox "$1" 10 72 \
        --output-fd 3 3>&1 </dev/tty >/dev/tty
}

# Runs on every exit path, including the signal traps below, so a terminal is
# never left with echo off and the staging file (which holds secrets) never
# outlives the run.
cleanup() {
    # Redirections apply left to right, so the group keeps a missing /dev/tty
    # from printing an error of its own.
    { stty echo </dev/tty; } 2>/dev/null || true
    [ -z "${ENV_STAGE:-}" ] || rm -f "$ENV_STAGE" "$ENV_STAGE.new"
    [ -z "${DOCKER_SCRIPT:-}" ] || rm -f "$DOCKER_SCRIPT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

confirm() {
    local answer=""
    if use_whiptail; then
        ui_yesno "$1" || return 1
        return 0
    fi
    printf '%s [y/N]: ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# A value Docker Compose's .env parser would mangle is refused at the prompt
# instead of reaching the services altered while the bootstrap scripts read it
# verbatim. scripts/lib.sh owns the rule (the Makefile's check-env calls the
# same function, so the two cannot drift); it is read here in a subshell
# because sourcing lib.sh would clobber this script's log/die. Post-clone
# only, which is where every prompt happens.
LIB_SH=""
VALUE_RULES=""

load_value_rules() {
    LIB_SH="$INSTALL_DIR/scripts/lib.sh"
    # `|| true`: set -e would abort on the failed substitution before the die
    # below could explain what is wrong.
    VALUE_RULES="$(sh -c '. "$1" >/dev/null 2>&1 && printf %s "$ENV_VALUE_RULES"' _ "$LIB_SH" || true)"
    [ -n "$VALUE_RULES" ] || die "could not read the .env value rules from $LIB_SH — is the checkout intact?"
}

# Fails closed: a lib.sh that stops sourcing makes every value unsafe rather
# than silently accepting it (load_value_rules already proved it sources).
value_is_safe() {
    sh -c '. "$1" >/dev/null 2>&1 && env_value_is_safe "$2"' _ "$LIB_SH" "$1"
}

require_safe() {
    value_is_safe "$2" || die "$1 $VALUE_RULES"
}

# ask VAR "label" "default" [secret] — resolution order: already-exported
# value > interactive answer > default. Secrets are read with echo disabled.
# Empty or unsafe answers re-prompt rather than abort, so a stray Enter cannot
# discard the answers already given.
ask() {
    local var="$1" label="$2" default="$3" secret="${4:-}"
    local current="" value=""

    eval "current=\${$var:-}"
    if [ -n "$current" ]; then
        require_safe "$var" "$current"
        # Announced: a value that happens to sit in the caller's shell profile
        # would otherwise be baked into .env with no prompt and no trace.
        if [ -n "$secret" ]; then
            log "Using the exported $var (value not displayed)"
        else
            log "Using the exported $var=$current"
        fi
        return 0
    fi

    if ! interactive; then
        [ -n "$default" ] || die "$var is required but no terminal is available: export $var and re-run"
        # Checked like every other path: the detected defaults (timezone from
        # /etc/timezone, the LAN address) are not invariants.
        require_safe "the detected default for $var" "$default"
        eval "$var=\$default"
        return 0
    fi

    local invalid=""
    while :; do
        if use_whiptail; then
            # A rejected answer is re-asked in the same dialog, reason first.
            local text="$label"
            [ -z "$invalid" ] || text="$invalid

$label"
            if [ -n "$secret" ]; then
                value="$(ui_passwordbox "$text")" || value=""
            else
                value="$(ui_inputbox "$text" "$default")" || value=""
            fi
        else
            [ -z "$invalid" ] || log "$invalid"
            if [ -n "$default" ] && [ -z "$secret" ]; then
                printf '%s [%s]: ' "$label" "$default" >/dev/tty
            else
                printf '%s: ' "$label" >/dev/tty
            fi

            if [ -n "$secret" ]; then
                stty -echo </dev/tty
                IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
                stty echo </dev/tty
                printf '\n' >/dev/tty
            else
                IFS= read -r value </dev/tty || die "no input available on /dev/tty for $var"
            fi
        fi

        [ -n "$value" ] || value="$default"
        if [ -z "$value" ]; then
            invalid="$var cannot be empty"
        elif ! value_is_safe "$value"; then
            invalid="$var $VALUE_RULES"
        else
            break
        fi
    done
    eval "$var=\$value"
}

ensure_base_tools() {
    local missing="" cmd=""
    for cmd in git make; do
        have "$cmd" || missing="$missing $cmd"
    done
    [ -n "$missing" ] || return 0

    if have apt-get && interactive && confirm "Missing tools:$missing — install them with apt-get?"; then
        # shellcheck disable=SC2086
        if ! $SUDO apt-get update -qq; then
            die "apt-get update failed — check your mirrors, install$missing manually and re-run"
        fi
        # shellcheck disable=SC2086
        if ! $SUDO apt-get install -y $missing; then
            die "apt-get could not install$missing — install them manually and re-run"
        fi
    else
        die "missing required tools:$missing — install them and re-run"
    fi
}

# Downloaded to a file first: `curl | sh` would hide a download failure (the
# pipeline reports sh's status, and sh on empty input exits 0).
install_docker() {
    # Checked here, not up front: this is curl's only use, so a wget-only host
    # that already has Docker (or declines this install) must not be refused.
    have curl || die "curl is required to download https://get.docker.com — install curl, or install Docker yourself (https://docs.docker.com/engine/install/debian/), then re-run"
    DOCKER_SCRIPT="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$DOCKER_SCRIPT" \
        || die "could not download https://get.docker.com — check network access and retry"
    sh "$DOCKER_SCRIPT"
    rm -f "$DOCKER_SCRIPT"
    DOCKER_SCRIPT=""
    have docker || die "the get.docker.com script did not install Docker"
    # Skipped as root: the group grant would be a no-op (the daemon socket is
    # already reachable) and sudo may not exist to carry it out.
    # shellcheck disable=SC2086
    [ -z "$SUDO" ] || $SUDO usermod -aG docker "$(id -un)"
}

# Networks compose does not pin a subnet for are auto-allocated, and only
# 172.30.0.0/16 is inside ALLOW_IP_RANGES. The daemon's default hands out /16s
# from 172.17.0.0/12 - fifteen in total, which this stack nearly exhausts, and
# the last ones land outside that range, where `lan@docker` answers a bare 403
# with nothing in the logs to say why. This gives 128 networks, all inside it,
# starting at .128 so it cannot collide with the /24s compose pins by hand.
#
# ip6tables is stated rather than left to its default because traefik's [::]
# publishes depend on it: without it the daemon programs no IPv6 DNAT, userland
# docker-proxy serves the listener instead and rewrites the source to a Docker
# gateway address - which is inside ALLOW_IP_RANGES, so `lan@docker` would admit
# every IPv6 caller. A default is not something to rest that on.
DOCKER_ADDRESS_POOL_JSON='{
  "default-address-pools": [
    { "base": "172.30.128.0/17", "size": 24 }
  ],
  "ip6tables": true
}'

# 0 when the version cannot be read, which reads as "old" and warns rather than
# staying quiet about the one thing this check exists for.
docker_server_major() {
    local major=""
    major="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
    case "$major" in
        ''|*[!0-9]*) major=0 ;;
    esac
    printf '%s' "$major"
}

warn_ip6tables() {
    log "WARNING: $1"
    log "  Traefik's [::] publishes then go through userland docker-proxy, which"
    log "  rewrites the client address to a Docker gateway one - so lan@docker sees"
    log "  a source it cannot judge. Add \"ip6tables\": true and restart Docker, or"
    log "  drop the [::] entries from traefik's ports in compose.yaml."
}

ensure_docker_address_pool() {
    local f=/etc/docker/daemon.json

    if [ -f "$f" ]; then
        # No JSON merge here on purpose: jq is not a dependency of this script and
        # silently rewriting an operator's daemon config is worse than saying so.
        if ! grep -q 'default-address-pools' "$f"; then
            log "WARNING: $f exists but sets no default-address-pools."
            log "  Docker will allocate networks outside ALLOW_IP_RANGES, which shows up"
            log "  as an unexplained 403 from Traefik. Add these keys and restart Docker:"
            printf '%s\n' "$DOCKER_ADDRESS_POOL_JSON" >&2
        fi
        # Absent is the case that matters, and the one a grep for `false` never
        # sees: this file is what an earlier run of this installer wrote, so
        # every upgraded host lands here with no ip6tables key at all. That is
        # only safe while the daemon defaults it on, which it has since 27.
        if grep -qE '"ip6tables"[[:space:]]*:[[:space:]]*false' "$f"; then
            warn_ip6tables "$f disables ip6tables."
        elif ! grep -q '"ip6tables"' "$f" && [ "$(docker_server_major)" -lt 27 ]; then
            warn_ip6tables "$f sets no ip6tables key, and this daemon defaults it off."
        fi
        return 0
    fi

    log "Configuring Docker's default address pool (172.30.128.0/17 in /24s) and ip6tables"
    # shellcheck disable=SC2086
    printf '%s\n' "$DOCKER_ADDRESS_POOL_JSON" | $SUDO tee "$f" >/dev/null \
        || die "could not write $f"
    # shellcheck disable=SC2086
    $SUDO systemctl restart docker \
        || die "wrote $f but could not restart Docker: check 'systemctl status docker'"
}

ensure_docker() {
    local daemon_ok=""

    if ! have docker; then
        if interactive && confirm "Docker is not installed. Install it now via https://get.docker.com?"; then
            install_docker
            docker info >/dev/null 2>&1 \
                || die "Docker is installed, but the docker group only takes effect at next login: log out and back in, then re-run this installer (it resumes where it left off)"
            daemon_ok=1
        else
            die "Docker is required: https://docs.docker.com/engine/install/debian/"
        fi
    fi

    docker compose version >/dev/null 2>&1 \
        || die "the Docker Compose plugin is missing: https://docs.docker.com/compose/install/linux/"

    [ -z "$daemon_ok" ] || return 0
    if ! docker info >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
            die "Docker only answers via sudo: run 'sudo usermod -aG docker $(id -un)', log out and back in, then re-run this installer"
        fi
        die "Docker daemon is not reachable: check 'systemctl status docker'"
    fi
}

# `-e`, not `-d`: .git is a file in worktree and submodule checkouts.
looks_like_clone() {
    [ -f "$1/compose.yaml" ] && [ -f "$1/.env.dist" ] && [ -e "$1/.git" ]
}

resolve_install_dir() {
    if [ -n "${PI_PCLOUD_DIR:-}" ]; then
        INSTALL_DIR="$PI_PCLOUD_DIR"
    elif looks_like_clone "$(pwd)"; then
        INSTALL_DIR="$(pwd)"
    elif [ "$(id -u)" -eq 0 ]; then
        # $HOME would bake /root into the systemd unit's WorkingDirectory,
        # leaving the stack unmanageable from the operator's account.
        INSTALL_DIR="/opt/pi-pcloud"
    else
        INSTALL_DIR="$HOME/pi-pcloud"
    fi
}

clone_or_update() {
    if [ -e "$INSTALL_DIR/.git" ]; then
        case "$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null)" in
            "$REPO_URL" | *pi-pcloud*)
                log "Existing clone in $INSTALL_DIR, fast-forwarding..."
                git -C "$INSTALL_DIR" pull --ff-only \
                    || log "WARNING: could not fast-forward (local changes?), continuing with current checkout"
                ;;
            *) die "$INSTALL_DIR is a git repository but not a pi-pcloud clone; set PI_PCLOUD_DIR to another path" ;;
        esac
    # An empty pre-created directory (permissions or mount setup) is fine:
    # git clone accepts it as a destination.
    elif [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        die "$INSTALL_DIR exists and is neither empty nor a pi-pcloud clone; set PI_PCLOUD_DIR to another path"
    else
        log "Cloning $REPO_URL into $INSTALL_DIR..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
}

# Delegates to lib.sh so the installer and the stack agree on .env parsing;
# the subshell keeps lib.sh's own log/die out of this script.
read_env_key() {
    sh -c '. "$1/scripts/lib.sh" >/dev/null 2>&1 && read_env_value_from_file "$2" "$3"' \
        _ "$INSTALL_DIR" "$1" "$2" \
        || die "could not read $2 from $1 — is $INSTALL_DIR/scripts/lib.sh intact?"
}

# Injection-safe upsert into the staging file: the value travels through awk's
# ENVIRON, never through a program string, so |, &, \ or quotes cannot corrupt
# it. Written under umask 077 so secrets never touch a world-readable file.
set_env() {
    local key="$1"
    (
        umask 077
        ENV_VALUE="$2" awk -v key="$key" '
            index($0, key "=") == 1 { print key "=" ENVIRON["ENV_VALUE"]; found = 1; next }
            { print }
            END { if (!found) print key "=" ENVIRON["ENV_VALUE"] }
        ' "$ENV_STAGE" >"$ENV_STAGE.new"
    )
    mv "$ENV_STAGE.new" "$ENV_STAGE"
}

# Same generator as scripts/rotate-password.sh, so fresh installs and
# rotations share one password policy; a fallback that changes the policy
# says so rather than downgrading silently.
gen_password() {
    local secret=""
    secret="$(sh -c '. "$1/scripts/lib.sh" >/dev/null 2>&1 && generate_secret' _ "$INSTALL_DIR" 2>/dev/null || true)"
    if [ -z "$secret" ]; then
        log "WARNING: scripts/lib.sh generate_secret unavailable; falling back to a 24-character random password"
        secret="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    fi
    [ "${#secret}" -ge 24 ] || die "could not generate a password (got ${#secret} characters)"
    printf '%s' "$secret"
}

# The Makefile owns the required-variable list (enforced by check-env), so it
# is asked to expand the list rather than scraped: a text scrape reads only the
# `:=` line and would silently miss a later `+=` append, leaving a variable
# unprompted until `make preflight` fails at the very end of the install. make
# is guaranteed by ensure_base_tools, and this runs after the clone. Tokens are
# still validated because they are eval'd as variable names below.
read_required_vars() {
    local raw="" var="" out=""

    raw="$(make -s -C "$INSTALL_DIR" print-required-vars 2>/dev/null || true)"
    for var in $raw; do
        case "$var" in
            *[!A-Z0-9_]* | '') die "unexpected token '$var' in the Makefile's REQUIRED_ENV_VARS" ;;
        esac
        out="$out $var"
    done
    [ -n "$out" ] || die "could not read REQUIRED_ENV_VARS from $INSTALL_DIR/Makefile ('make print-required-vars' returned nothing)"
    printf '%s' "$out"
}

ask_required() {
    local var="$1" label="" default="" secret=""

    case "$var" in
        HOST_NAME) label="Domain name (e.g. pi.example.com)" ;;
        EMAIL) label="Admin email address" ;;
        ADMIN_USER)
            label="Admin username"
            default="admin"
            ;;
        PASSWORD)
            label="Admin password (Enter = generate one)"
            default="$GENERATED_PASSWORD"
            secret=1
            ;;
        TIMEZONE)
            label="Timezone"
            default="$DETECTED_TZ"
            ;;
        HOST_LAN_IP)
            label="Static LAN IP of this machine (a changing DHCP lease breaks Headscale and local DNS)"
            default="$DETECTED_IP"
            ;;
        CLOUDFLARE_DNS_API_TOKEN)
            label="Cloudflare API token (DNS edit on your zone)"
            secret=1
            ;;
        CLOUDFLARE_ZONE_ID) label="Cloudflare zone ID" ;;
        *) label="$var" ;;
    esac
    ask "$var" "$label" "$default" "$secret"
}

detect_network() {
    local route=""
    route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    DETECTED_IP="" DETECTED_IFACE="" DETECTED_GATEWAY="" DETECTED_SUBNET=""
    # shellcheck disable=SC2086 # trusted `ip route` output, split on purpose
    set -- $route
    while [ $# -gt 1 ]; do
        case "$1" in
            src) DETECTED_IP="$2" ;;
            dev) DETECTED_IFACE="$2" ;;
            via) DETECTED_GATEWAY="$2" ;;
        esac
        shift
    done
    if [ -n "$DETECTED_IFACE" ]; then
        DETECTED_SUBNET="$(ip -4 route show dev "$DETECTED_IFACE" proto kernel scope link 2>/dev/null | awk 'NR == 1 { print $1 }')"
    fi
}

# Asked of the kernel rather than guessed from the name (bridges over Wi-Fi,
# renamed interfaces): macvlan, which gives Pi-hole its LAN address, does not
# work over Wi-Fi.
is_wireless() {
    [ -d "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ]
}

# `ip route get` honours policy routing, so an active full-tunnel VPN (wg0,
# tun0, tailscale0 with an exit node) can own the default route and be picked
# as the parent — and macvlan over a tunnel cannot work either. Recognised by
# the kernel's ARP type (1 = ARPHRD_ETHER) and the tun marker file rather than
# by name; an unknown type is treated as usable, since only a positive match
# should block the install.
is_virtual_parent() {
    local kind=""
    [ ! -e "/sys/class/net/$1/tun_flags" ] || return 0
    kind="$(cat "/sys/class/net/$1/type" 2>/dev/null || true)"
    case "$kind" in
        '' | 1) return 1 ;;
        *) return 0 ;;
    esac
}

# An unattended run has nobody to read the warning, so an auto-detected
# unusable parent stops the install instead; an explicit HOST_LAN_PARENT export
# is taken as a deliberate choice and only warns.
check_parent_usable() {
    local reason="$1"
    log "WARNING: $LAN_PARENT $reason; macvlan (Pi-hole's LAN address) needs a wired LAN parent"
    if interactive; then
        confirm "Continue with $LAN_PARENT anyway?" \
            || die "connect the machine over Ethernet, or export HOST_LAN_PARENT, then re-run"
    elif [ -z "${HOST_LAN_PARENT:-}" ]; then
        die "the auto-detected parent $LAN_PARENT $reason and no terminal is available: connect the machine over Ethernet, or export HOST_LAN_PARENT to override, then re-run"
    fi
}

# Exported values win over detection, mirroring the prompt contract. Resolved
# before any prompt so an abort here cannot discard typed credentials.
resolve_network() {
    detect_network
    LAN_PARENT="${HOST_LAN_PARENT:-$DETECTED_IFACE}"
    LAN_SUBNET="${HOST_LAN_SUBNET:-$DETECTED_SUBNET}"
    LAN_GATEWAY="${HOST_LAN_GATEWAY:-$DETECTED_GATEWAY}"

    # These five reach .env without passing through a prompt, so they are
    # checked here instead — a newline in an exported value would otherwise
    # inject extra lines into .env. An empty value is safe (nothing is written).
    require_safe HOST_LAN_PARENT "$LAN_PARENT"
    require_safe HOST_LAN_SUBNET "$LAN_SUBNET"
    require_safe HOST_LAN_GATEWAY "$LAN_GATEWAY"
    require_safe ALLOW_IP_RANGES "${ALLOW_IP_RANGES:-}"
    require_safe PIHOLE_IP "${PIHOLE_IP:-}"
    require_safe STREMIO_IP "${STREMIO_IP:-}"

    if [ -z "$LAN_PARENT" ] || [ -z "$LAN_SUBNET" ] || [ -z "$LAN_GATEWAY" ]; then
        log "Could not determine the LAN layout (interface/subnet/gateway)"
        if interactive && confirm "Continue with the 192.168.1.0/24 defaults from .env.dist (and fix .env afterwards)?"; then
            log "WARNING: review HOST_LAN_*, ALLOW_IP_RANGES and PIHOLE_IP in .env — a wrong LAN range locks every client out"
            # Dropped as a set: keeping a half-detected layout (a default route
            # with no gateway, e.g. an LTE modem) would mix the real subnet with
            # .env.dist's 192.168.1.1 and leave the macvlan gateway outside its
            # own subnet. Falling back means falling back to all of .env.dist.
            LAN_PARENT="" LAN_SUBNET="" LAN_GATEWAY=""
            return 0
        fi
        die "no usable network layout: export HOST_LAN_PARENT, HOST_LAN_SUBNET and HOST_LAN_GATEWAY (plus PIHOLE_IP), then re-run"
    fi

    if is_wireless "$LAN_PARENT"; then
        check_parent_usable "is a Wi-Fi interface"
    elif is_virtual_parent "$LAN_PARENT"; then
        check_parent_usable "is not an Ethernet interface (a VPN tunnel?)"
    fi
}

# Rebuilt member by member: the fixed entries (loopback, VPN, Docker) stay
# owned by .env.dist, and a missing LAN member is an error rather than a
# silent no-op. No sed interpolation (a CIDR is full of regex metacharacters).
build_allow_ip_ranges() {
    RANGES="$1" DIST_LAN="$2" LAN="$3" awk 'BEGIN {
        count = split(ENVIRON["RANGES"], members, ",")
        out = ""
        replaced = 0
        for (i = 1; i <= count; i++) {
            member = members[i]
            if (member == ENVIRON["DIST_LAN"]) {
                member = ENVIRON["LAN"]
                replaced = 1
            }
            out = (out == "" ? member : out "," member)
        }
        if (!replaced) exit 1
        print out
    }'
}

# A free static address for a macvlan container, from the candidate octets in
# preference order (.250 for Pi-hole and .251 for Stremio, the .env.dist
# defaults), skipping the host itself, the gateway, an address already handed
# to another container, and anything that answers a ping.
# Silence is not proof an address is free (a sleeping device, a DHCP lease
# handed out later), hence the warning at the end of the run — but an answer is
# proof it is taken. Skipped when ping is unavailable rather than treating
# every candidate as free.
pick_lan_ip() {
    local prefix="$1" taken="$2" octet="" candidate=""
    shift 2
    for octet in "$@"; do
        candidate="$prefix.$octet"
        [ "$candidate" != "${HOST_LAN_IP:-}" ] || continue
        [ "$candidate" != "$LAN_GATEWAY" ] || continue
        [ "$candidate" != "$taken" ] || continue
        if have ping && ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
            log "$candidate already answers on the LAN, trying the next address"
            continue
        fi
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

write_network_settings() {
    local dist_ranges="" dist_lan="" ranges="" prefix="" pihole_ip="" stremio_ip=""

    [ -z "$LAN_PARENT" ] || set_env HOST_LAN_PARENT "$LAN_PARENT"
    [ -z "$LAN_SUBNET" ] || set_env HOST_LAN_SUBNET "$LAN_SUBNET"
    [ -z "$LAN_GATEWAY" ] || set_env HOST_LAN_GATEWAY "$LAN_GATEWAY"

    # Written before the no-subnet bail below: an exported value is the
    # documented override, so it must survive a fallback to the .env.dist LAN
    # defaults (someone whose LAN really is 192.168.1.0/24 but who needs
    # another Pi-hole address exports PIHOLE_IP alone).
    [ -z "${ALLOW_IP_RANGES:-}" ] || set_env ALLOW_IP_RANGES "$ALLOW_IP_RANGES"
    [ -z "${PIHOLE_IP:-}" ] || set_env PIHOLE_IP "$PIHOLE_IP"
    [ -z "${STREMIO_IP:-}" ] || set_env STREMIO_IP "$STREMIO_IP"

    # Nothing left to derive without a subnet: the .env.dist defaults stand.
    [ -n "$LAN_SUBNET" ] || return 0

    if [ -z "${ALLOW_IP_RANGES:-}" ]; then
        dist_ranges="$(read_env_key "$INSTALL_DIR/.env.dist" ALLOW_IP_RANGES)"
        dist_lan="$(read_env_key "$INSTALL_DIR/.env.dist" HOST_LAN_SUBNET)"
        if ranges="$(build_allow_ip_ranges "$dist_ranges" "$dist_lan" "$LAN_SUBNET")"; then
            set_env ALLOW_IP_RANGES "$ranges"
        else
            die "the ALLOW_IP_RANGES default in .env.dist no longer contains the LAN subnet ($dist_lan); export ALLOW_IP_RANGES and re-run"
        fi
    fi

    case "$LAN_SUBNET" in
        *.0/24) prefix="${LAN_SUBNET%.0/24}" ;;
    esac

    if [ -n "${PIHOLE_IP:-}" ]; then
        pihole_ip="$PIHOLE_IP"
    elif [ -n "$prefix" ]; then
        pihole_ip="$(pick_lan_ip "$prefix" "" 250 249 248 247)" \
            || die "no free address left for Pi-hole in $LAN_SUBNET; export PIHOLE_IP and re-run"
        set_env PIHOLE_IP "$pihole_ip"
    elif interactive; then
        log "Pi-hole needs a free static address inside $LAN_SUBNET (outside your router's DHCP range)"
        ask PIHOLE_IP "Pi-hole IP" ""
        set_env PIHOLE_IP "$PIHOLE_IP"
        pihole_ip="$PIHOLE_IP"
    else
        die "non-/24 subnet ($LAN_SUBNET): export PIHOLE_IP with a free address inside it and re-run"
    fi

    # Stremio's LAN address is used by the `stremio-lan` profile only, which is
    # off by default and not part of "all": a missing one must not stop an
    # install that will never enable it, so this warns where Pi-hole's dies and
    # never spends a prompt on it. Left unset, .env.dist's 192.168.1.251 would
    # sit outside any other subnet and `up stremio-lan` would refuse the address.
    [ -z "${STREMIO_IP:-}" ] || return 0
    if [ -z "$prefix" ]; then
        log "WARNING: non-/24 subnet ($LAN_SUBNET): set STREMIO_IP in .env by hand before enabling the stremio-lan profile"
        return 0
    fi
    if stremio_ip="$(pick_lan_ip "$prefix" "$pihole_ip" 251 252 253 254)"; then
        set_env STREMIO_IP "$stremio_ip"
    else
        log "WARNING: no free address left for Stremio in $LAN_SUBNET; set STREMIO_IP in .env by hand before enabling the stremio-lan profile"
    fi
}

# Which optional services to run, via Docker Compose profiles (each optional
# service carries a profile named after itself; see docs/CONFIGURATION.md,
# "Choosing which services run"). An exported COMPOSE_PROFILES wins like every
# prompt. Anything else — no terminal, no python3, a cancelled screen — keeps
# the .env.dist default (all) rather than stopping the install, since
# `make config` can change the selection at any time.
# The clone owns the picker, so the install offers the very same screen as
# `make config` later on — sections, nested companions and linked toggling
# included — instead of a second checklist that would drift from it. It reads
# the staged .env, whose .env.dist default ticks everything.
pick_services() {
    ENV_FILE="$ENV_STAGE" sh "$INSTALL_DIR/scripts/services.sh" pick
}

select_services() {
    local value="" rc=0

    if [ -n "${COMPOSE_PROFILES:-}" ]; then
        require_safe COMPOSE_PROFILES "$COMPOSE_PROFILES"
        log "Using the exported COMPOSE_PROFILES=$COMPOSE_PROFILES"
        set_env COMPOSE_PROFILES "$COMPOSE_PROFILES"
        return 0
    fi

    value="$(pick_services)" || rc="$?"
    case "$rc" in
        0) ;;
        1)
            log "Selection cancelled; every optional service stays enabled"
            return 0
            ;;
        3)
            log "WARNING: the selection paired two services that cannot run together; every optional service stays enabled"
            return 0
            ;;
        *)
            log "Every optional service stays enabled (run 'make config' in $INSTALL_DIR to choose)"
            return 0
            ;;
    esac

    [ -n "$value" ] || log "WARNING: no services selected; only the core infrastructure will run"
    require_safe COMPOSE_PROFILES "$value"
    set_env COMPOSE_PROFILES "$value"
}

configure_env() {
    if [ -f "$ENV_FILE" ]; then
        log "Keeping existing $ENV_FILE"
        return 0
    fi
    # Set only after the early return above: the EXIT trap removes
    # "$ENV_STAGE"*, and the keep-existing-.env path must not delete a
    # user's own .env.tmp file.
    ENV_STAGE="$ENV_FILE.tmp"
    rm -f "$ENV_STAGE" "$ENV_STAGE.new"

    local required_vars="" var="" value=""
    load_value_rules
    required_vars="$(read_required_vars)"

    # Everything that can abort runs before the first prompt, so a refused
    # confirmation never discards typed credentials.
    resolve_network

    DETECTED_TZ=""
    if [ -z "${TIMEZONE:-}" ]; then
        DETECTED_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
        [ -n "$DETECTED_TZ" ] || DETECTED_TZ="Etc/UTC"
    fi
    GENERATED_PASSWORD=""
    [ -n "${PASSWORD:-}" ] || GENERATED_PASSWORD="$(gen_password)"

    log "Configuring $ENV_FILE (press Enter to accept a [default])"
    for var in $required_vars; do
        ask_required "$var"
    done

    cp "$INSTALL_DIR/.env.dist" "$ENV_STAGE"
    chmod 600 "$ENV_STAGE"
    for var in $required_vars; do
        eval "value=\${$var:-}"
        set_env "$var" "$value"
    done
    select_services
    write_network_settings
    mv "$ENV_STAGE" "$ENV_FILE"
    ENV_STAGE=""

    if [ -n "$GENERATED_PASSWORD" ] && [ "${PASSWORD:-}" = "$GENERATED_PASSWORD" ]; then
        log "A password was generated and stored as PASSWORD in $ENV_FILE (not displayed)"
    fi
    log "Optional settings (SMTP, S3 backups, language) can be filled in $ENV_FILE later"
}

check_privileges() {
    if [ "$(id -u)" -eq 0 ]; then
        log "WARNING: running as root; prefer a regular account (sudo is requested only where needed)"
        SUDO=""
        return 0
    fi
    have sudo || die "sudo is required: 'make install' applies sysctl, /etc/hosts and systemd changes"
    if ! interactive && ! sudo -n true 2>/dev/null; then
        die "unattended installs need passwordless sudo ('make install' applies sysctl, /etc/hosts and systemd changes)"
    fi
}

main() {
    check_privileges
    ensure_base_tools
    ensure_docker
    ensure_docker_address_pool
    resolve_install_dir
    clone_or_update
    ENV_FILE="$INSTALL_DIR/.env"
    configure_env

    cd "$INSTALL_DIR"
    local host_name="" pihole_ip=""
    pihole_ip="$(read_env_key "$ENV_FILE" PIHOLE_IP)"
    [ -z "$pihole_ip" ] || log "Pi-hole will claim $pihole_ip — make sure it sits outside your router's DHCP range (edit PIHOLE_IP in .env now if not)"

    log "Running preflight checks..."
    make preflight
    log "Installing (sudo will be requested for systemd/sysctl setup)..."
    make install

    host_name="$(read_env_key "$ENV_FILE" HOST_NAME)"
    log "Installation complete. First startup takes a few minutes (make logs to watch)."
    log "Next: create users at https://lldap.${host_name:-<HOST_NAME>} then sign in at https://auth.${host_name:-<HOST_NAME>}"
    log "See docs/INSTALLATION.md (First Login) for the remaining one-time steps."
}

main "$@"
