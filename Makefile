.PHONY: help install install-system uninstall pg-upgrade start stop restart update update-images status logs doctor preflight check-env print-required-vars test smoke lint services enable disable config headscale-register headscale-reset rotate-password rotate-password-full rotate-secret check-secrets recovery-kit api-keys

REQUIRED_ENV_VARS := HOST_NAME TIMEZONE EMAIL ADMIN_USER PASSWORD HOST_LAN_IP CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID

MAKEFLAGS += --no-print-directory

PROJECT_PATH := $(shell pwd)
# Immediate assignment: make expands it while reading this file, before any
# recipe runs — so `update` can diff it against HEAD after its own `git pull`.
HEAD_BEFORE_PULL := $(shell git rev-parse HEAD 2>/dev/null)
UNIT         := pi-pcloud.service
WATCH_UNIT   := pi-pcloud-authelia-ntfy.service
WAN_UNIT     := pi-pcloud-wan-allowlist.service
COMPOSE      := docker compose

# Sourcing scripts/lib.sh from a recipe, guarded so a broken lib.sh under the
# >/dev/null aborts with a diagnosis instead of a bare Error 2.
#
# PROJECT_DIR and ENV_FILE are preset because lib.sh derives them from
# `dirname "$$0"`, and under a recipe $$0 is the shell itself — "sh" — so they
# resolve to the *parent* of the repository and to ../.env. Every caller here
# happens to pass an explicit path to read_env_value_from_file, so nothing reads
# the wrong file today; the next one to reach for get_env_value would. lib.sh
# takes both from the environment when set. SCRIPT_NAME comes along so its log
# lines read [make] rather than [sh].
LIB_SH = if [ ! -r scripts/lib.sh ]; then \
             echo "❌ scripts/lib.sh is missing or unreadable"; exit 1; \
         fi; \
         PROJECT_DIR="$(CURDIR)"; ENV_FILE="$(CURDIR)/.env"; SCRIPT_NAME=make; \
         export PROJECT_DIR ENV_FILE SCRIPT_NAME; \
         . scripts/lib.sh >/dev/null 2>&1

# The pi-pcloud command and its completions. /usr/local/bin is on PATH for both
# users and sudo; the completion directories are Debian's own.
BIN_LINK        := /usr/local/bin/pi-pcloud
BASH_COMPLETION := /usr/share/bash-completion/completions/pi-pcloud
ZSH_COMPLETION  := /usr/share/zsh/vendor-completions/_pi-pcloud
# Empty when make already runs as root: root-only images often ship without a
# sudo binary at all (install.sh applies the same rule to its own commands).
SUDO         := $(if $(filter 0,$(shell id -u)),,sudo)
# Resolved by path, not by name: sysctl lives in /usr/sbin, which a root shell
# entered with `su` (no dash) does not have on its PATH — and $(SUDO) is empty
# there, so sudo's secure_path no longer covers it either.
SYSCTL       := $(firstword $(wildcard /usr/sbin/sysctl /sbin/sysctl) sysctl)

# A second word on the command line is an argument, not a target: `make enable
# stremio` reads better than `make enable s=stremio`, and the pi-pcloud command
# can then pass its own arguments straight through. The stub rule keeps make
# from trying to build that word as a goal; s=<service> still works.
ifneq (,$(filter enable disable headscale-register,$(firstword $(MAKECMDGOALS))))
GOAL_ARG := $(word 2,$(MAKECMDGOALS))
ifneq (,$(GOAL_ARG))
$(eval $(GOAL_ARG):;@:)
endif
endif
SERVICE       := $(if $(s),$(s),$(GOAL_ARG))
HEADSCALE_KEY := $(GOAL_ARG)

help:
	@echo "Commands:"
	@echo "  install          Install & enable systemd unit, start stack and initialize"
	@echo "  install-system   Re-apply the host files only (sysctl, /etc/hosts, units, command)"
	@echo "  uninstall        Stop stack, remove all data/volumes and uninstall systemd units"
	@echo "  start            Start stack"
	@echo "  stop             Stop stack"
	@echo "  restart          Restart stack"
	@echo "  update           Pull the repository and updated images, rebuild, apply in place"
	@echo "  update-images    Images only: pull, rebuild, recreate just what moved"
	@echo "  status           Show systemd status"
	@echo "  logs             Follow compose logs"
	@echo "  services         List optional services and whether each is enabled"
	@echo "  enable <name>    Enable an optional service (updates COMPOSE_PROFILES, starts it, runs its init hooks)"
	@echo "  disable <name>   Disable an optional service (updates COMPOSE_PROFILES, stops it)"
	@echo "  config           Interactive checklist to choose which services run"
	@echo "  doctor           Report anything outside its threshold (disk, RAM, temp, containers, backups)"
	@echo "  preflight        Quick env readiness check"
	@echo "  headscale-register <key> Register a headscale node"
	@echo "  headscale-reset  Reset all Headscale nodes, preauth keys, and IP allocations"
	@echo "  check-env        Validate required .env variables"
	@echo "  test             Run every suite: installer, check-env, CLI, services, start sequence, compose invariants, routing and SARIF merge (no host changes)"
	@echo "  smoke            Probe the running stack through Traefik: every router loaded, LAN admitted, outside refused"
	@echo "  lint             Run every static check CI runs (shell, YAML, Python, Dockerfiles, workflows, secrets)"
	@echo "  pg-upgrade to=<image> Migrate Postgres to a new major (dump/restore, old data kept)"
	@echo "  rotate-password       Rotate PASSWORD after a leak (LLDAP admin + Authelia only, no Postgres)"
	@echo "  rotate-password-full  Same, plus every Postgres role and every other service using PASSWORD"
	@echo "  recovery-kit          Print the five values that open the off-site backup, to store on paper"
	@echo "  api-keys              Print the gateway base URLs and tokens, to paste into a client elsewhere"
	@echo "  help             This help"

# Both the reader and the safety rule come from scripts/lib.sh, which install.sh
# also calls: a second copy of the rule here would let the installer and this
# check disagree the moment either is tightened.
check-env:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@echo "🔍 Checking required .env variables..."; \
	$(LIB_SH); \
	command -v env_value_is_safe >/dev/null 2>&1 || { echo "❌ scripts/lib.sh did not define env_value_is_safe"; exit 1; }; \
	missing=0; \
	for var in $(REQUIRED_ENV_VARS); do \
		val=$$(read_env_value_from_file .env "$$var"); \
		if [ -z "$$val" ]; then echo "  ❌ $$var is not set or empty"; missing=1; \
		elif ! env_value_is_safe "$$val"; then \
			echo "  ❌ $$var $$ENV_VALUE_RULES"; missing=1; \
		fi; \
	done; \
	if [ $$missing -eq 1 ]; then exit 1; fi
	@echo "✔ Required .env variables OK"

# Read by install.sh so it prompts for exactly this list: make expands `+=`
# appends and line continuations that a text scrape of this file would miss.
print-required-vars:
	@echo "$(REQUIRED_ENV_VARS)"

# Same suites CI runs. Every test works on a temporary copy - and compose-test
# renders with --no-interpolate, so not even .env is read - so this touches
# neither .env nor the host.
test:
	@sh tests/install-test.sh
	@sh tests/check-env-test.sh
	@sh tests/cli-test.sh
	@sh tests/services-test.sh
	@sh tests/stack-up-test.sh
	@sh tests/compose-test.sh
	@sh tests/trilium-api-contract.sh
	@sh tests/routing-test.sh
	@sh tests/sarif-merge-test.sh

# Needs a running stack, which is why it is not part of `test`: it asks Traefik
# for the routing table it actually loaded, then checks each router answers a
# LAN address and refuses one outside the allowlist. CI runs the same script
# after `up --wait`.
#
# For the outside half it creates a throwaway network outside the allowlist and
# attaches Traefik and the probe container to it for the duration, then removes
# it. Nothing is restarted and no configuration is written.
smoke:
	@sh tests/routing-smoke.sh

# The same script CI runs, so a green local run means a green CI run. Gates
# whose tool is missing are reported as skipped; CI adds LINT_STRICT=1 to make
# a skip fail.
lint:
	@sh scripts/lint.sh

preflight: check-env
	@echo "🔍 Preflight...";
	@if ! docker info >/dev/null 2>&1; then echo "❌ Docker not reachable"; exit 1; fi
	@echo "✔ Docker OK"
	@if mount | grep -q ' type cgroup2 '; then echo "✔ cgroup v2"; else echo "ℹ legacy cgroup"; fi
	@if docker run --rm -m 32m busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0 sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' | grep -qE '33554432|32'; then echo "✔ memory limits enforced"; else echo "⚠ memory limits NOT enforced"; fi
	@# A host with IPv6 but no delegated prefix needs nothing - the allowlist entry
	@# stays empty and everything runs over IPv4. A kernel with IPv6 compiled out or
	@# switched off is the one that cannot start the stack as it stands.
	@if [ -e /proc/net/if_inet6 ]; then echo "✔ kernel has IPv6"; else 		echo "⚠ kernel has no IPv6 (ipv6.disable=1?)"; 		echo "   Docker cannot create a network with an IPv6 subnet, and docker-proxy"; 		echo "   cannot bind [::]:443, so the stack will not start as it stands."; 		echo "   docs/NETWORKING.md, 'A host with no IPv6 at all', lists what to remove."; 	fi
	@echo "Done"

install: check-env install-system
	@if [ "$(SKIP_START)" = "1" ]; then \
		echo "⏭️  SKIP_START=1 set; not starting stack"; \
	else \
		echo "🚀 Starting stack..."; \
		$(SUDO) systemctl start $(UNIT); \
		$(MAKE) start; \
	fi
	@echo "✅ Installation complete"

# Everything this repository installs outside itself: sysctl, the /etc/hosts
# records, the systemd units (rendered with this checkout's path) and the
# pi-pcloud command. Split out of `install` so `update` can re-apply it after
# a pull: these are copies, so a unit or a completion changed upstream would
# otherwise sit stale on the host until the next install. Every step is
# idempotent. The command itself is a symlink into the checkout and needs no
# refresh, unlike the completions beside it.
install-system:
	@echo "📦 Installing system files..."
	@echo "🧰 Applying host sysctl settings..."
	$(SUDO) cp config/sysctl.d/pi-pcloud.conf /etc/sysctl.d/99-pi-pcloud.conf
	$(SUDO) $(SYSCTL) --system >/dev/null
	@echo "💽 Sizing host swap..."
	@# Best-effort: a host that cannot take a bigger swap file is not a failed
	@# install. The script says why and leaves the size to the next reboot.
	@./scripts/configure-swap.sh || echo "  ⚠ swap sizing skipped"
	@echo "🐧 Applying kernel command-line parameters..."
	@# Also best-effort, and never blocking: everything here is a diagnostic or
	@# a performance setting that a reboot picks up, not a prerequisite.
	@./scripts/configure-kernel-params.sh || echo "  ⚠ kernel parameters skipped"
	@echo "🌐 Adding local DNS overrides to /etc/hosts..."
	@# Read through lib.sh, like check-env above: a third copy of the .env
	@# reader here would drift from the one install.sh and the scripts use.
	@$(LIB_SH); \
	command -v read_env_value_from_file >/dev/null 2>&1 || { echo "❌ scripts/lib.sh did not define read_env_value_from_file"; exit 1; }; \
	HOST_NAME_VAL=$$(read_env_value_from_file .env HOST_NAME); \
	HOST_LAN_IP_VAL=$$(read_env_value_from_file .env HOST_LAN_IP); \
	if [ -n "$$HOST_NAME_VAL" ] && [ -n "$$HOST_LAN_IP_VAL" ]; then \
		$(SUDO) sed -i "/# pi-pcloud local overrides/,/# end pi-pcloud local overrides/d" /etc/hosts; \
		printf "# pi-pcloud local overrides\n%s\theadscale.%s\n# end pi-pcloud local overrides\n" "$$HOST_LAN_IP_VAL" "$$HOST_NAME_VAL" | $(SUDO) tee -a /etc/hosts >/dev/null; \
		echo "  ✔ headscale.$$HOST_NAME_VAL -> $$HOST_LAN_IP_VAL"; \
	else \
		echo "  ⚠ HOST_NAME or HOST_LAN_IP not set, skipping"; \
	fi
	@# Rendered through mktemp rather than a predictable /tmp path: any other
	@# local account could pre-create /tmp/<unit> as a symlink it controls and
	@# have its own ExecStart installed as a root unit by the sudo below.
	@# mktemp also keeps the destination untouched if the render fails.
	@set -e; \
	rendered=$$(mktemp); \
	trap 'rm -f "$$rendered"' EXIT INT TERM; \
	$(LIB_SH); \
	LAN_PARENT_VAL=$$(unquote_env_value "$$(read_env_value_from_file .env HOST_LAN_PARENT)"); \
	LAN_PARENT_VAL=$${LAN_PARENT_VAL:-eth0}; \
	for unit in $(UNIT) $(WATCH_UNIT) $(WAN_UNIT) nextcloud-cron.service; do \
		sed -e 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' \
		    -e "s|__HOST_LAN_PARENT__|$$(sed_escape "$$LAN_PARENT_VAL")|g" \
		    "config/systemd/system/$$unit" > "$$rendered"; \
		$(SUDO) install -m 644 -o root -g root "$$rendered" "/etc/systemd/system/$$unit"; \
	done
	$(SUDO) cp config/systemd/system/nextcloud-cron.timer /etc/systemd/system/
	$(SUDO) cp config/systemd/system/pi-pcloud-wan-allowlist.timer /etc/systemd/system/
	$(SUDO) systemctl daemon-reload
	$(SUDO) systemctl enable $(UNIT) $(WATCH_UNIT)
# --now on the timers: `enable` alone arms them for the next boot only, so a
# fresh install waits until then for the first run.
	$(SUDO) systemctl enable --now nextcloud-cron.timer pi-pcloud-wan-allowlist.timer
	@echo "✅ Systemd units installed"
	@echo "🔗 Installing the pi-pcloud command..."
# A symlink, not a copy: the command follows this checkout, so a git pull
# updates it and there is no rendered duplicate to drift.
	$(SUDO) ln -sfn $(PROJECT_PATH)/scripts/pi-pcloud $(BIN_LINK)
	$(SUDO) mkdir -p $(dir $(BASH_COMPLETION)) $(dir $(ZSH_COMPLETION))
	$(SUDO) cp config/completion/pi-pcloud.bash $(BASH_COMPLETION)
	$(SUDO) cp config/completion/_pi-pcloud $(ZSH_COMPLETION)
	@echo "✅ pi-pcloud available on PATH (new shells get completion)"

uninstall:
	@echo "🗑️  Uninstalling pi-pcloud..."
	@echo ""
	@echo "⚠️  WARNING: This will remove ALL data including:"
	@echo "   - Docker volumes (pi-hole, headscale, etc.)"
	@echo "   - Bind-mount data dirs: ./data/nextcloud, ./data/postgres*, ./data/n8n, ./data/immich"
	@echo "   - Generated config: ./data/authelia-config/configuration.yml"
	@echo "   - Generated config: ./config/headplane/config.yaml" 
	@echo "   - Generated config: ./config/headscale/config.yaml"
	@echo "   - Generated config: ./config/headscale/policy.hujson"
	@echo "   - Generated config: ./config/ntfy/ntfy.env"
	@echo "   - Generated config: ./config/beszel-agent/agent.env"
	@echo "   - Systemd service units"
	@echo ""
	@printf "Are you sure? Type 'yes' to confirm: "; read -r confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo ""
	@echo "🛑 Stopping services..."
	-$(SUDO) systemctl stop pi-pcloud-wan-allowlist.timer 2>/dev/null || true
	-$(SUDO) systemctl stop $(WATCH_UNIT) 2>/dev/null || true
	-$(SUDO) systemctl stop $(UNIT) 2>/dev/null || true
	@echo "🐳 Removing containers and volumes..."
	-$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	@echo "🧹 Removing bind-mount data directories..."
# postgres* and not postgres: from 18 the cluster directory carries the major
# (./data/postgres18), so the bare name leaves the whole cluster behind. A
# reinstall then finds a non-empty PGDATA, never runs init-databases.sh, and
# every service fails to authenticate against roles still holding the old
# PASSWORD. The glob also takes any leftover pg-major-upgrade.sh dump directory.
	-$(SUDO) rm -rf ./data/nextcloud ./data/postgres* ./data/n8n ./data/immich ./data/lldap ./data/authelia-config
	@echo "🧹 Removing generated config files..."
	-rm -f ./config/headplane/config.yaml
	-rm -f ./config/headscale/config.yaml
	-rm -f ./config/headscale/policy.hujson
	-rm -f ./config/ntfy/ntfy.env
	-rm -f ./config/beszel-agent/agent.env
	@echo "🧰 Removing host sysctl settings..."
	-$(SUDO) rm -f /etc/sysctl.d/99-pi-pcloud.conf
	-$(SUDO) $(SYSCTL) --system >/dev/null
	@echo "💽 Restoring original swap config..."
	@if [ -f /etc/dphys-swapfile.pi-pcloud.bak ]; then \
		$(SUDO) mv /etc/dphys-swapfile.pi-pcloud.bak /etc/dphys-swapfile; \
		echo "  ✔ /etc/dphys-swapfile restored (applies on next reboot)"; \
	else \
		echo "  ℹ no backup found, leaving /etc/dphys-swapfile as is"; \
	fi
	@echo "🐧 Removing kernel command-line parameters..."
	-@./scripts/configure-kernel-params.sh remove || echo "  ⚠ kernel parameters left as they are"
	@echo "🌐 Removing local DNS overrides from /etc/hosts..."
	-$(SUDO) sed -i "/# pi-pcloud local overrides/,/# end pi-pcloud local overrides/d" /etc/hosts
	@echo "🧹 Removing the pi-pcloud command..."
	-$(SUDO) rm -f $(BIN_LINK) $(BASH_COMPLETION) $(ZSH_COMPLETION)
	@echo "🧹 Removing systemd units..."
	-$(SUDO) systemctl disable $(UNIT) $(WATCH_UNIT) nextcloud-cron.timer pi-pcloud-wan-allowlist.timer 2>/dev/null || true
	-$(SUDO) rm -f /etc/systemd/system/$(UNIT)
	-$(SUDO) rm -f /etc/systemd/system/$(WATCH_UNIT)
	-$(SUDO) rm -f /etc/systemd/system/$(WAN_UNIT)
	-$(SUDO) rm -f /etc/systemd/system/pi-pcloud-wan-allowlist.timer
	-$(SUDO) rm -f /etc/systemd/system/nextcloud-cron.service
	-$(SUDO) rm -f /etc/systemd/system/nextcloud-cron.timer
	-$(SUDO) systemctl daemon-reload
	@echo "✅ Uninstall complete"
	@echo ""
	@echo "ℹ️  Note: .env file preserved. Remove manually if needed."

start:
	@echo "🚀 Starting pi-pcloud stack..."
	$(SUDO) systemctl start $(UNIT)
	@echo "✅ Stack started"

stop:
	@echo "🛑 Stopping pi-pcloud stack..."
	$(COMPOSE) down --remove-orphans
	$(SUDO) systemctl stop $(UNIT) 2>/dev/null || true
	@echo "✅ Stack stopped"

restart: stop start

# Apply in place: `up -d` recreates only the containers whose image or spec
# moved, so one new image no longer costs a full-stack restart. Through systemd
# when the unit is inactive, so the stack never runs behind an `inactive` unit;
# directly otherwise, since `start` on an already-active oneshot is a no-op.
# Root either way: the hooks write root-owned config, and headscale's leaves
# orphan API keys when run as a user.
define apply_stack
if $(SUDO) systemctl is-active --quiet $(UNIT); then \
	$(SUDO) sh scripts/stack-up.sh; \
else \
	$(SUDO) systemctl start $(UNIT); \
fi
endef

# Images are refreshed while the stack runs, so nothing is interrupted until
# compose swaps the containers that actually have a new image. `pull` covers
# what COMPOSE_PROFILES selects and skips the images built here, which
# `build --pull` rebuilds against their updated bases. The final prune only
# touches dangling layers, never one a container still references.
update:
	@echo "🔄 Updating pi-pcloud..."
	@branch=$$(git rev-parse --abbrev-ref HEAD); 	if [ "$$branch" != "main" ]; then echo "  ⚠ on branch $$branch, not main"; fi
	@echo "📥 Repository..."
	@git pull --ff-only
	$(MAKE) check-env
	@echo "📦 Images (the stack keeps running)..."
	@$(COMPOSE) pull --ignore-buildable
	@echo "🔨 Locally built images..."
	@$(COMPOSE) build --pull
	$(MAKE) install-system
# The watcher runs on the host, outside compose, so nothing above picks up a
# change to its script. try-restart leaves it alone when it is not running.
	@$(SUDO) systemctl try-restart $(WATCH_UNIT)
# `up -d` compares a container's image and spec, not the contents of the files
# bind-mounted into it, so a config the pull rewrote would sit on disk unread.
# That is the one case where the old down/up did necessary work. scripts/ is in
# the path list too: the generated configs (headscale, backrest, headplane,
# authelia) are gitignored, so a pull that re-renders one shows up only as a
# change to the *-pre-start.sh that writes it. (A config edited by hand is
# still `make restart`; the diff cannot see it.)
# `systemctl restart`, not `$(MAKE) restart`: make runs any recipe line
# mentioning $(MAKE) even under `--dry-run`.
	@if [ -n "$(HEAD_BEFORE_PULL)" ] && ! git diff --quiet $(HEAD_BEFORE_PULL) HEAD -- config/ scripts/; then \
		echo "🔁 The pull changed config/ or scripts/; restarting so services read it..."; \
		$(SUDO) systemctl restart $(UNIT); \
	else \
		echo "🚀 Applying changes (only what moved is recreated)..."; \
		$(apply_stack); \
	fi
	@echo "🧹 Reclaiming space from the replaced images..."
	@docker image prune -f | tail -n1
	@echo "✅ Update complete"

# `make update` minus everything that needs the repository to have moved: no
# pull, no host files. For when only the pinned images are stale.
update-images:
	@echo "📦 Updating images (the stack keeps running)..."
	$(MAKE) check-env
	@$(COMPOSE) pull --ignore-buildable
	@echo "🔨 Locally built images..."
	@$(COMPOSE) build --pull
	@echo "🚀 Recreating the containers whose image moved..."
	@$(apply_stack)
	@echo "🧹 Reclaiming space from the replaced images..."
	@docker image prune -f | tail -n1
	@echo "✅ Images up to date"

status:
	@echo "📊 Status"
	$(SUDO) systemctl status $(UNIT) --no-pager -l
	-$(SUDO) systemctl status $(WATCH_UNIT) --no-pager -l

logs:
	@echo "📝 Logs (Ctrl+C to exit)"
	$(COMPOSE) logs -f --tail=100

# Optional services are toggled through Docker Compose profiles: every optional
# service carries a profile named after itself (plus the catch-all "all"), and
# COMPOSE_PROFILES in .env selects which run. All the logic (enabled-ness
# computation, .env rewriting, the per-service pre-start/bootstrap hooks and
# the interactive checklist) lives in scripts/services.sh — these targets are
# thin wrappers around it.
services:
	@/bin/sh scripts/services.sh list

enable:
	@/bin/sh scripts/services.sh enable "$(SERVICE)"

disable:
	@/bin/sh scripts/services.sh disable "$(SERVICE)"

config:
	@/bin/sh scripts/services.sh config

# The same endpoint the assistant calls for the `anomalies` topic, so the shell
# and the chat cannot disagree. Asked from inside the container because
# system-tools only exposes its port on the compose networks, and with python3
# because the image (python:3.14-slim) ships no curl - the same call its
# healthcheck makes.
doctor:
	@echo "🩺 Diagnostic"
	@$(COMPOSE) exec -T system-tools python3 -c \
		"import urllib.request as r; print(r.urlopen('http://localhost:8000/status/anomalies').read().decode())" \
		|| echo "❌ system-tools unreachable - check 'docker compose ps' and 'make logs'"
	@echo
	@echo "🔑 Secret consistency"
	@# Without sudo, so `make doctor` stays non-interactive: the one target that
	@# needs root then reports "not verifiable here" instead of prompting. Drift
	@# here is otherwise silent until a widget 401s or a backup cannot open its
	@# repository, which is exactly what a diagnostic is for.
	@for t in $$(sh scripts/rotate-secret.sh --list); do \
		sh scripts/rotate-secret.sh "$$t" --check >/dev/null 2>&1; \
		case $$? in \
			0) echo "  ✔ $$t" ;; \
			2) echo "  · $$t (not verifiable without sudo)" ;; \
			*) echo "  ✘ $$t - run: make rotate-secret TARGET=$$t" ;; \
		esac; \
	done

# Postgres major upgrades are dump/restore: the immich-app/postgres image ships
# one major's binaries, so pg_upgrade is not available. The old data directory
# is left untouched, so rollback is reverting compose.yaml *and rebuilding
# backrest* — its pinned pgNN-client moved with the server, and a client newer
# than the server writes dumps that server cannot replay.
#   make pg-upgrade to=ghcr.io/immich-app/postgres:18-vectorchord1.1.1@sha256:...
# This target is one step of a procedure - docs/POSTGRES-UPGRADE.md has the rest,
# including the trap that starting the stack on the new compose file first
# silently initialises an empty cluster.
pg-upgrade:
	@if [ -z "$(to)" ]; then \
		echo "❌ Target image missing (use: make pg-upgrade to=<image>)"; exit 1; \
	fi
	@sh scripts/pg-major-upgrade.sh --to "$(to)" --apply

headscale-register:
	@echo "🔐 Registering headscale node..."
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@if [ -z "$(HEADSCALE_KEY)" ]; then echo "❌ Key missing (use: make headscale-register <key>)"; exit 1; fi
	@$(LIB_SH); \
	command -v read_env_value_from_file >/dev/null 2>&1 || { echo "❌ scripts/lib.sh did not define read_env_value_from_file"; exit 1; }; \
	EMAIL_FROM_ENV="$${EMAIL:-$$(read_env_value_from_file .env EMAIL)}"; \
	if [ -z "$$EMAIL_FROM_ENV" ]; then echo "❌ EMAIL not set in .env"; exit 1; fi; \
	$(COMPOSE) run --rm headscale nodes register --key "$(HEADSCALE_KEY)" --user "$$EMAIL_FROM_ENV"

headscale-reset:
	@echo "⚠️  This will WIPE ALL Headscale nodes, preauth keys, and IP allocations!"
	@printf "Are you sure? Type 'yes' to confirm: "; read -r confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo "🧹 Deleting all Headscale nodes..."
	-docker compose exec -T headscale headscale nodes list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale nodes delete --identifier {} --force
	@echo "🧹 Deleting all Headscale preauth keys..."
	-docker compose exec -T headscale headscale preauthkeys list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale preauthkeys expire --id {} --force
	@echo "🧹 Resetting Headscale IP allocations (restarting service)..."
	-docker compose restart headscale
	@echo "✅ Headscale reset complete"

rotate-password:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh --skip-postgres

rotate-password-full:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh

# The per-service secrets rotate-password.sh deliberately leaves alone. TARGET is
# required because each one has its own set of consumers to propagate to.
rotate-secret:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make rotate-secret TARGET=<name>"; echo; \
		sh scripts/rotate-secret.sh --list | sed 's/^/  /'; exit 1; \
	fi
	$(SUDO) sh scripts/rotate-secret.sh "$(TARGET)"

# Reports which secrets have drifted from their consumers - the failure mode that
# is otherwise silent until a widget 401s or a backup cannot open its repository.
check-secrets:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@rc=0; for t in $$(sh scripts/rotate-secret.sh --list); do \
		$(SUDO) sh scripts/rotate-secret.sh "$$t" --check >/dev/null 2>&1; \
		case $$? in \
			0) echo "  ✔ $$t" ;; \
			2) echo "  · $$t (not verifiable here)" ;; \
			*) echo "  ✘ $$t"; rc=1 ;; \
		esac; \
	done; exit $$rc

# No check-env dependency: this reads config/backrest/config.json, not .env, and
# it is most wanted precisely when the rest of the install is in a bad way.
recovery-kit:
	sh scripts/recovery-kit.sh

# Deliberately not "print every secret": .env holds the rest and Backrest
# carries it off-site, while these are generated on first start and shown in no
# UI, so a machine that is not this one has no other way to get them.
api-keys:
	sh scripts/api-keys.sh
