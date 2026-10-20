.PHONY: help install install-system uninstall pg-upgrade start stop restart update update-images status logs doctor preflight check-env print-required-vars test smoke lint services enable disable config headscale-register headscale-reset rotate-password rotate-password-full rotate-secret check-secrets recovery-kit api-keys

REQUIRED_ENV_VARS := HOST_NAME TIMEZONE EMAIL ADMIN_USER PASSWORD HOST_LAN_IP CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID

MAKEFLAGS += --no-print-directory

UNIT         := pi-pcloud.service
WATCH_UNIT   := pi-pcloud-authelia-ntfy.service
COMPOSE      := docker compose

# Empty when make already runs as root: root-only images often ship without a
# sudo binary at all (install.sh applies the same rule to its own commands).
SUDO         := $(if $(filter 0,$(shell id -u)),,sudo)

# A second word on the command line is an argument, not a target: `make enable
# stremio` reads better than `make enable s=stremio`, and the pi-pcloud command
# can then pass its own arguments straight through. The stub rule keeps make
# from trying to build that word as a goal; s=<service> still works. A word
# starting with a dash needs `--` before it, or make reads it as one of its own
# options: `make uninstall -- --purge`. pi-pcloud adds the `--` itself.
ifneq (,$(filter enable disable headscale-register uninstall,$(firstword $(MAKECMDGOALS))))
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

uninstall: ## [--purge] | Remove the stack, its state and every host file, keeping media; --purge deletes media too (asks first)
	@sh scripts/uninstall.sh "$(GOAL_ARG)"

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

doctor: ## Report anything outside its threshold (disk, RAM, temp, containers, backups)
	@sh scripts/doctor.sh

check-env: ## Validate required .env variables
	@sh scripts/check-env.sh $(REQUIRED_ENV_VARS)

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
	@sh tests/operator-commands-test.sh
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
	@sh scripts/preflight.sh

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
	@sh scripts/headscale-nodes.sh register "$(HEADSCALE_KEY)"

headscale-reset: ## Reset all Headscale nodes, preauth keys, and IP allocations
	@sh scripts/headscale-nodes.sh reset

rotate-password: ## Rotate PASSWORD after a leak (LLDAP admin + Authelia only, no Postgres)
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh --skip-postgres

rotate-password-full: ## Same, plus every Postgres role and every other service using PASSWORD
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh

rotate-secret: ## TARGET=<name> | Rotate one per-service secret and propagate it (no TARGET lists them)
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@$(if $(TARGET),$(SUDO) )sh scripts/rotate-secret.sh "$(TARGET)"

check-secrets: ## Report which secrets have drifted from their consumers; changes nothing
	@sh scripts/check-secrets.sh

# No check-env dependency: this reads config/backrest/config.json, not .env, and
# it is most wanted precisely when the rest of the install is in a bad way.
recovery-kit: ## Print the five values that open the off-site backup, to store on paper
	sh scripts/recovery-kit.sh

# Deliberately not "print every secret": .env holds the rest and Backrest
# carries it off-site, while these are generated on first start and shown in no
# UI, so a machine that is not this one has no other way to get them.
api-keys: ## Print the gateway base URLs and tokens, to paste into a client elsewhere
	sh scripts/api-keys.sh
