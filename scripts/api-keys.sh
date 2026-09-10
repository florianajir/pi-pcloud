#!/bin/sh
# Print the gateway credentials a client presents, with the base URL each one
# opens, ready to paste into a tool on another machine.
#
# Scoped to the gateway on purpose. This is not a general secret dumper: .env
# already holds the rest, Backrest already carries it off-site, and a command
# that prints everything gets run casually. These are the values with no other
# home - generated on first start, shown nowhere in any UI, and needed on a
# machine that is not this one.
#
# The stored files carry no prefix; the `sk-` belongs to the credential, which
# is why it is added here and in agentgateway-pre-start.sh both.
set -eu

. "$(dirname "$0")/lib.sh"

# These open every model the gateway fronts, including paid providers.
umask 077

main() {
    local secrets_dir="" host_name="" llm_key="" agent_key=""

    secrets_dir="$(resolve_data_location_path)/agentgateway/secrets"
    [ -d "$secrets_dir" ] || die "no $secrets_dir - has the stack ever started?"

    for f in llm_api_key agent_api_key; do
        [ -r "$secrets_dir/$f" ] \
            || die "cannot read $secrets_dir/$f - run this as the user that owns the stack, or with sudo"
    done

    host_name="$(get_env_value_clean HOST_NAME)"
    [ -n "$host_name" ] || host_name="pi.lan"

    llm_key="sk-$(cat "$secrets_dir/llm_api_key")"
    agent_key="sk-$(cat "$secrets_dir/agent_api_key")"

    cat <<EOF

  Gateway API keys — treat these like passwords.

  Local model (Open WebUI uses this one too)
    Base URL  https://llm.$host_name/v1
    Token     $llm_key

  Groq — full upstream model catalogue
    Base URL  https://llm.$host_name/groq/v1
    Token     $agent_key

  OpenRouter — full upstream model catalogue
    Base URL  https://llm.$host_name/openrouter/v1
    Token     $agent_key

  The two path routes accept the local-model token as well; the separate one
  exists so revoking a tool on a laptop does not lock Open WebUI out.

  Reachable from the LAN and the tailnet only. Rotate by deleting the file in
  $secrets_dir and running \`make config\`, then
  \`docker compose up -d agentgateway\` - \`restart\` keeps the old value.

EOF
}

main "$@"
