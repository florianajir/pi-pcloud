.PHONY: help install install-system uninstall pg-upgrade start stop restart update update-images status logs doctor preflight check-env print-required-vars test smoke lint services enable disable config headscale-register headscale-reset rotate-password rotate-password-full rotate-secret check-secrets recovery-kit api-keys

REQUIRED_ENV_VARS := HOST_NAME TIMEZONE EMAIL ADMIN_USER PASSWORD HOST_LAN_IP CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID

MAKEFLAGS += --no-print-directory

UNIT         := pi-pcloud.service
WATCH_UNIT   := pi-pcloud-authelia-ntfy.service
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

# Empty when make already runs as root: root-only images often ship without a
# sudo binary at all (install.sh applies the same rule to its own commands).
SUDO         := $(if $(filter 0,$(shell id -u)),,sudo)

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

# Generated from the `## ` comment on each target, so a new target cannot be
# missing from it: `## <args> | text` prints the arguments beside the name, and
# a target with no such comment is internal (print-required-vars, for install.sh).
help: ## This help
	@echo "Commands:"
	@awk '/^[a-z][a-z0-9-]*:.*## / { \
		name = $$1; sub(/:.*/, "", name); \
		text = $$0; sub(/^[^#]*## /, "", text); \
		bar = index(text, " | "); \
		if (bar) { name = name " " substr(text, 1, bar - 1); text = substr(text, bar + 3) } \
		printf "  %-28s %s\n", name, text \
	}' $(firstword $(MAKEFILE_LIST))

install: check-env install-system ## Install & enable systemd unit, start stack and initialize
	@if [ "$(SKIP_START)" = "1" ]; then \
		echo "⏭️  SKIP_START=1 set; not starting stack"; \
	else \
		echo "🚀 Starting stack..."; \
		$(SUDO) systemctl start $(UNIT); \
		$(MAKE) start; \
	fi
	@echo "✅ Installation complete"

install-system: ## Re-apply the host files only (sysctl, swap, kernel command line, /etc/hosts, units, command)
	@sh scripts/install-system.sh

uninstall: ## Stop stack, remove all data/volumes and every host file (asks first)
	@sh scripts/uninstall.sh

start: ## Start stack
	@echo "🚀 Starting pi-pcloud stack..."
	$(SUDO) systemctl start $(UNIT)
	@echo "✅ Stack started"

stop: ## Stop stack
	@echo "🛑 Stopping pi-pcloud stack..."
	$(COMPOSE) down --remove-orphans
	$(SUDO) systemctl stop $(UNIT) 2>/dev/null || true
	@echo "✅ Stack stopped"

restart: stop start ## Restart stack

update: ## Pull the repository and updated images, rebuild, apply in place
	@sh scripts/update.sh

update-images: ## Images only: pull, rebuild, recreate just what moved
	@sh scripts/update.sh --images

status: ## Show systemd status
	@echo "📊 Status"
	$(SUDO) systemctl status $(UNIT) --no-pager -l
	-$(SUDO) systemctl status $(WATCH_UNIT) --no-pager -l

logs: ## Follow compose logs
	@echo "📝 Logs (Ctrl+C to exit)"
	$(COMPOSE) logs -f --tail=100

# Optional services are toggled through Docker Compose profiles: every optional
# service carries a profile named after itself (plus the catch-all "all"), and
# COMPOSE_PROFILES in .env selects which run. All the logic (enabled-ness
# computation, .env rewriting, the per-service pre-start/bootstrap hooks and
# the interactive checklist) lives in scripts/services.sh — these targets are
# thin wrappers around it.
services: ## List optional services and whether each is enabled
	@/bin/sh scripts/services.sh list

enable: ## <name> | Enable an optional service (updates COMPOSE_PROFILES, starts it, runs its init hooks)
	@/bin/sh scripts/services.sh enable "$(SERVICE)"

disable: ## <name> | Disable an optional service (updates COMPOSE_PROFILES, stops it)
	@/bin/sh scripts/services.sh disable "$(SERVICE)"

config: ## Interactive checklist to choose which services run
	@/bin/sh scripts/services.sh config

# The same endpoint the assistant calls for the `anomalies` topic, so the shell
# and the chat cannot disagree. Asked from inside the container because
# system-tools only exposes its port on the compose networks, and with python3
# because the image (python:3.14-slim) ships no curl - the same call its
# healthcheck makes.
doctor: ## Report anything outside its threshold (disk, RAM, temp, containers, backups)
	@echo "🩺 Diagnostic"
	@$(COMPOSE) exec -T system-tools python3 -c \
		"import urllib.request as r; print(r.urlopen('http://localhost:8000/status/anomalies').read().decode())" \
		|| echo "❌ system-tools unreachable - check 'docker compose ps' and 'make logs'"
	@echo
	@echo "🧠 Memory ceilings"
	@# Read on the host, not through system-tools: the anomalies above answer
	@# "is the machine in trouble", which is a host-wide question, while this
	@# one is per-container and has no threshold to cross - a ceiling being hit
	@# costs a service its page cache and stalls nobody, so it never shows up
	@# in PSI and never belongs in a findings list. It is still the only way to
	@# tell a ceiling that is doing something from one that is decoration.
	@sh scripts/ram-usage.sh report
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

# Both the reader and the safety rule come from scripts/lib.sh, which install.sh
# also calls: a second copy of the rule here would let the installer and this
# check disagree the moment either is tightened.
check-env: ## Validate required .env variables
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
test: ## Run the test suites against temporary copies (no host changes)
	@sh tests/install-test.sh
	@sh tests/check-env-test.sh
	@sh tests/lib-test.sh
	@sh tests/cli-test.sh
	@sh tests/services-test.sh
	@sh tests/ram-usage-test.sh
	@sh tests/stack-up-test.sh
	@sh tests/changed-services-test.sh
	@sh tests/update-test.sh
	@sh tests/install-system-test.sh
	@sh tests/uptime-kuma-watchdog-test.sh
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
smoke: ## Probe the running stack through Traefik: every router loaded, LAN admitted, outside refused
	@sh tests/routing-smoke.sh

# The same script CI runs, so a green local run means a green CI run. Gates
# whose tool is missing are reported as skipped; CI adds LINT_STRICT=1 to make
# a skip fail.
lint: ## Run every static check CI runs (shell, YAML, Python, Dockerfiles, workflows, secrets, docs)
	@sh scripts/lint.sh

preflight: check-env ## Quick env readiness check
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

# Postgres major upgrades are dump/restore: the immich-app/postgres image ships
# one major's binaries, so pg_upgrade is not available. The old data directory
# is left untouched, so rollback is reverting compose/compose-core.yaml *and rebuilding
# backrest* — its pinned pgNN-client moved with the server, and a client newer
# than the server writes dumps that server cannot replay.
#   make pg-upgrade to=ghcr.io/immich-app/postgres:18-vectorchord1.1.1@sha256:...
# This target is one step of a procedure - docs/POSTGRES-UPGRADE.md has the rest,
# including the trap that starting the stack on the new compose file first
# silently initialises an empty cluster.
pg-upgrade: ## to=<image> | Migrate Postgres to a new major (dump/restore, old data kept)
	@if [ -z "$(to)" ]; then \
		echo "❌ Target image missing (use: make pg-upgrade to=<image>)"; exit 1; \
	fi
	@sh scripts/pg-major-upgrade.sh --to "$(to)" --apply

headscale-register: ## <key> | Register a headscale node
	@echo "🔐 Registering headscale node..."
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@if [ -z "$(HEADSCALE_KEY)" ]; then echo "❌ Key missing (use: make headscale-register <key>)"; exit 1; fi
	@$(LIB_SH); \
	command -v read_env_value_from_file >/dev/null 2>&1 || { echo "❌ scripts/lib.sh did not define read_env_value_from_file"; exit 1; }; \
	EMAIL_FROM_ENV="$${EMAIL:-$$(read_env_value_from_file .env EMAIL)}"; \
	if [ -z "$$EMAIL_FROM_ENV" ]; then echo "❌ EMAIL not set in .env"; exit 1; fi; \
	$(COMPOSE) run --rm headscale nodes register --key "$(HEADSCALE_KEY)" --user "$$EMAIL_FROM_ENV"

headscale-reset: ## Reset all Headscale nodes, preauth keys, and IP allocations
	@echo "⚠️  This will WIPE ALL Headscale nodes, preauth keys, and IP allocations!"
	@printf "Are you sure? Type 'yes' to confirm: "; read -r confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo "🧹 Deleting all Headscale nodes..."
	-docker compose exec -T headscale headscale nodes list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale nodes delete --identifier {} --force
	@echo "🧹 Deleting all Headscale preauth keys..."
	-docker compose exec -T headscale headscale preauthkeys list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale preauthkeys expire --id {} --force
	@echo "🧹 Resetting Headscale IP allocations (restarting service)..."
	-docker compose restart headscale
	@echo "✅ Headscale reset complete"

rotate-password: ## Rotate PASSWORD after a leak (LLDAP admin + Authelia only, no Postgres)
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh --skip-postgres

rotate-password-full: ## Same, plus every Postgres role and every other service using PASSWORD
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh

# The per-service secrets rotate-password.sh deliberately leaves alone. TARGET is
# required because each one has its own set of consumers to propagate to.
rotate-secret: ## TARGET=<name> | Rotate one per-service secret and propagate it (no TARGET lists them)
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make rotate-secret TARGET=<name>"; echo; \
		sh scripts/rotate-secret.sh --list | sed 's/^/  /'; exit 1; \
	fi
	$(SUDO) sh scripts/rotate-secret.sh "$(TARGET)"

# Reports which secrets have drifted from their consumers - the failure mode that
# is otherwise silent until a widget 401s or a backup cannot open its repository.
check-secrets: ## Report which secrets have drifted from their consumers; changes nothing
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
recovery-kit: ## Print the five values that open the off-site backup, to store on paper
	sh scripts/recovery-kit.sh

# Deliberately not "print every secret": .env holds the rest and Backrest
# carries it off-site, while these are generated on first start and shown in no
# UI, so a machine that is not this one has no other way to get them.
api-keys: ## Print the gateway base URLs and tokens, to paste into a client elsewhere
	sh scripts/api-keys.sh
