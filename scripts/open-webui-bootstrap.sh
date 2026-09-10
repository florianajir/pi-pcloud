#!/bin/sh
# Registers the agentgateway LLM endpoint as an Open WebUI connection and seeds
# the settings a fresh install needs.
#
# OPENAI_API_BASE_URL and friends are "PersistentConfig" variables: Open WebUI
# copies them into its database on first start and reads the database from then
# on, so on an instance that already has connections the compose environment is
# ignored and the model never appears in the picker.
#
# The connection API needs an admin session token, and logins go through Authelia
# SSO (ENABLE_LOGIN_FORM=false), so there is no scriptable credential to obtain
# one with - the config table is the practical route.
#
# Restarts open-webui only when something changed; the running process caches the
# config it loaded at startup.
set -eu

. "$(dirname "$0")/lib.sh"

# Read from the file rather than the environment: this script writes to the
# database directly, and so never sees the variables compose expands.
DEFAULT_LANGUAGE="$(get_env_value DEFAULT_LANGUAGE)"
[ -n "$DEFAULT_LANGUAGE" ] || DEFAULT_LANGUAGE="en-US"
# This value is spliced into SQL literals below (and into TTS/LOCALE/SUGGESTIONS
# version strings that are spliced in turn), so a quote in it would run as SQL
# against a superuser connection. env_value_is_safe does not cover that: it only
# rejects a quote at the very start or end of the value. A BCP-47 tag needs
# nothing outside this set.
case "$DEFAULT_LANGUAGE" in
    *[!A-Za-z0-9_-]*)
        die "DEFAULT_LANGUAGE may only contain letters, digits, '-' and '_'"
        ;;
esac

GATEWAY_URL="http://agentgateway:4000/v1"
# Separate connections because they are separate base URLs, which is also why
# nothing on them shows up under /v1. See docs/AI.md.
GROQ_URL="http://agentgateway:4000/groq/v1"
OPENROUTER_URL="http://agentgateway:4000/openrouter/v1"
# The same file compose exports the gateway's own key from, so this cannot
# disagree with it. Hex, which is what makes it safe to splice into SQL.
GATEWAY_KEY_FILE="$(resolve_data_location_path)/agentgateway/secrets/llm_api_key"
# The path routes accept the key above too; using the external-client one keeps
# revoking either from touching the other.
AGENT_KEY_FILE="$(resolve_data_location_path)/agentgateway/secrets/agent_api_key"
# Must match the model `name` in config/agentgateway/config.yaml, which is in
# turn LLAMA_ARG_ALIAS in compose.yaml.
LLAMA_MODEL="gemma-4-e2b-it"
# Each settings group carries its own marker row, so it is seeded once and never
# re-imposed - anything changed afterwards in Admin Settings stays changed. Bump
# a version to seed that group's new values once.
DEFAULTS_MARKER="pi-pcloud.local_ai_defaults"
DEFAULTS_VERSION='"2"'
# models.default_metadata. A config row, not a workspace one, so it needs no
# admin account and applies from the first boot rather than the first SSO login.
GLOBAL_META_MARKER="pi-pcloud.global_model_metadata"
GLOBAL_META_VERSION='"1"'
# The workspace row the Ollama-era naming left behind. Inert - get_all_models
# drops a base-model override whose base no backend serves - but it shows up in
# the model table and in every backup after it. Marked rather than deleted once,
# so a database restore that brings it back is cleaned up again.
STALE_MODEL_MARKER="pi-pcloud.ollama_model_cleanup"
STALE_MODEL_VERSION='"1"'
STALE_MODEL_ID="gemma4:e2b"
TTS_MARKER="pi-pcloud.local_tts_defaults"
# The language is part of the version, so changing DEFAULT_LANGUAGE re-seeds the
# voice once.
TTS_VERSION="\"2-$DEFAULT_LANGUAGE\""
TTS_BASE_URL="http://piper:8000/v1"
case "$DEFAULT_LANGUAGE" in
    fr*) TTS_VOICE="fr_FR-siwis-medium" ;;
    # Also what piper falls back to on its own when no voice matches the
    # language. Seeding the same name keeps Admin Settings > Audio showing the
    # voice that will actually answer, rather than one silently substituted on
    # every request.
    *)   TTS_VOICE="en_US-lessac-medium" ;;
esac
# No language in the version: parakeet-tdt-0.6b-v3 is multilingual and picks the
# language off the audio, so DEFAULT_LANGUAGE has nothing to select here.
STT_MARKER="pi-pcloud.local_stt_defaults"
STT_VERSION='"1"'
STT_BASE_URL="http://parakeet:8000/v1"
# Sent as the `model` field and otherwise ignored - the container serves the one
# model it was built with - so the admin page names something recognisable.
STT_MODEL="parakeet-tdt-0.6b-v3"
LOCALE_MARKER="pi-pcloud.default_locale"
LOCALE_VERSION="\"1-$DEFAULT_LANGUAGE\""
# Open access to anyone Authelia lets in, rather than Open WebUI's approval queue.
ACCESS_MARKER="pi-pcloud.open_access"
ACCESS_VERSION='"2"'
TOOLS_MARKER="pi-pcloud.system_tools"
TOOLS_VERSION='"1"'
TOOLS_URL="http://system-tools:8000"
# Stable id: the tool is attached to a model as "server:<id>", so it must not
# change between runs or the reference on the model breaks.
TOOLS_ID="pi-system"
SUGGESTIONS_MARKER="pi-pcloud.prompt_suggestions"
SUGGESTIONS_VERSION="\"5-$DEFAULT_LANGUAGE\""
# No tile for `memory`: `overview` already reports RAM.
suggestions_fr() { cat <<'JSON'
[
  {"title": ["Combien d'espace disque", "reste-t-il ?"],
   "content": "Combien d'espace disque reste-t-il sur le serveur ?"},
  {"title": ["Y a-t-il des anomalies", "sur le serveur ?"],
   "content": "Y a-t-il des anomalies sur le serveur en ce moment ?"},
  {"title": ["Donne-moi l'état", "du serveur"],
   "content": "Donne-moi un état général du serveur."},
  {"title": ["Le Pi chauffe-t-il ?", "température et charge"],
   "content": "Quelle est la température du CPU et la charge en ce moment ?"},
  {"title": ["Depuis quand", "le serveur tourne-t-il ?"],
   "content": "Depuis combien de temps le serveur tourne-t-il ?"},
  {"title": ["Qui est en ligne", "sur le tailnet ?"],
   "content": "Quels appareils sont actuellement en ligne sur le tailnet ?"},
  {"title": ["La sauvegarde de cette nuit", "est-elle passée ?"],
   "content": "Est-ce que la sauvegarde de cette nuit est passée ?"},
  {"title": ["Quelque chose a-t-il", "redémarré récemment ?"],
   "content": "Est-ce que quelque chose a redémarré récemment ?"},
  {"title": ["Montre-moi les erreurs", "des services en panne"],
   "content": "Montre-moi les erreurs des services en panne."}
]
JSON
}

suggestions_en() { cat <<'JSON'
[
  {"title": ["How much disk space", "is left?"],
   "content": "How much disk space is left on the server?"},
  {"title": ["Are there any anomalies", "on the server?"],
   "content": "Are there any anomalies on the server right now?"},
  {"title": ["Give me an overview", "of the server"],
   "content": "Give me a general overview of the server."},
  {"title": ["Is the Pi hot?", "temperature and load"],
   "content": "What is the CPU temperature and the load right now?"},
  {"title": ["How long has the server", "been up?"],
   "content": "How long has the server been running?"},
  {"title": ["Who is online", "on the tailnet?"],
   "content": "Which devices are currently online on the tailnet?"},
  {"title": ["Did last night's", "backup succeed?"],
   "content": "Did last night's backup succeed?"},
  {"title": ["Has anything", "restarted recently?"],
   "content": "Has anything restarted recently?"},
  {"title": ["Show me the errors", "from failing services"],
   "content": "Show me the errors from the services that are failing."}
]
JSON
}

case "$DEFAULT_LANGUAGE" in
    fr*) SUGGESTIONS="$(suggestions_fr)" ;;
    *)   SUGGESTIONS="$(suggestions_en)" ;;
esac

psql_owui() {
    compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d open-webui "$@"
}

# Three states, not two. `absent` means Open WebUI has not persisted its
# connection list yet, so the compose environment is what seeds it and there is
# nothing to do here. `stale` means the URL is registered but the key stored
# beside it is not the one the gateway now accepts - which `present` used to be
# indistinguishable from, so a wrong or rotated key could never be repaired and
# the only remedy was editing the database by hand.
connection_state() {
    local url="$1" key="$2"

    # Scalar subqueries inside a one-row derived table, not a join: both config
    # rows are absent on a fresh install, and any join of two empty sides
    # returns no row at all - which would read as "cannot query" and skip.
    psql_owui -tAc \
        "SELECT CASE
             WHEN s.urls IS NULL THEN 'absent'
             WHEN NOT (s.urls ? '$url') THEN 'missing'
             WHEN coalesce(s.keys ->> (
                 SELECT (ord - 1)::int
                 FROM jsonb_array_elements_text(s.urls) WITH ORDINALITY AS t(val, ord)
                 WHERE t.val = '$url'
                 LIMIT 1
             ), '') = '$key' THEN 'current'
             ELSE 'stale'
         END
         FROM (SELECT
                 (SELECT value::jsonb FROM config WHERE key = 'openai.api_base_urls') AS urls,
                 (SELECT value::jsonb FROM config WHERE key = 'openai.api_keys') AS keys
              ) s;" \
        2>/dev/null | tr -d ' \r\n'
}

# The repair half of the above: overwrite the key at the URL's own index. The
# arrays are parallel, so the index is looked up from the URL list rather than
# assumed.
update_connection_key() {
    local url="$1" key="$2"

    psql_owui -q <<SQL
DO \$\$
DECLARE
    target text := '$url';
    urls   jsonb;
    keys   jsonb;
    idx    int;
    stamp  bigint := extract(epoch from now())::bigint;
BEGIN
    SELECT value::jsonb INTO urls FROM config WHERE key = 'openai.api_base_urls';
    IF urls IS NULL OR NOT (urls ? target) THEN
        RETURN;
    END IF;

    SELECT ord - 1 INTO idx
        FROM jsonb_array_elements_text(urls) WITH ORDINALITY AS t(val, ord)
        WHERE t.val = target
        LIMIT 1;

    SELECT coalesce(value::jsonb, '[]'::jsonb) INTO keys FROM config WHERE key = 'openai.api_keys';
    keys := coalesce(keys, '[]'::jsonb);
    WHILE jsonb_array_length(keys) <= idx LOOP
        keys := keys || to_jsonb(''::text);
    END LOOP;

    UPDATE config SET value = jsonb_set(keys, ARRAY[idx::text], to_jsonb('$key'::text))::json,
            updated_at = stamp
        WHERE key = 'openai.api_keys';
END
\$\$;
SQL
}

# Via the file so a credential never reaches argv, and hex-checked before being
# spliced into a SQL literal.
read_api_key() {
    local file="$1" key=""

    [ -r "$file" ] || return 1
    key="$(tr -d '\r\n' < "$file")"
    case "$key" in
        "" | *[!0-9a-fA-F]*) return 1 ;;
    esac
    printf 'sk-%s' "$key"
}

add_connection() {
    local url="$1" key="$2" prefix="$3"

    # api_base_urls, api_keys and api_configs are parallel: the config for a URL
    # is looked up by its index in the URL list, so all three have to grow
    # together. api_keys is padded first in case it is short, then the key is
    # appended at the index this URL lands on - the gateway's apiKey policy is
    # `strict`, so it rejects a call without one.
    psql_owui -q <<SQL
DO \$\$
DECLARE
    target text := '$url';
    urls   jsonb;
    keys   jsonb;
    idx    int;
    stamp  bigint := extract(epoch from now())::bigint;
BEGIN
    SELECT value::jsonb INTO urls FROM config WHERE key = 'openai.api_base_urls';
    IF urls IS NULL OR urls ? target THEN
        RETURN;
    END IF;

    idx := jsonb_array_length(urls);

    SELECT coalesce(value::jsonb, '[]'::jsonb) INTO keys FROM config WHERE key = 'openai.api_keys';
    keys := coalesce(keys, '[]'::jsonb);
    WHILE jsonb_array_length(keys) < idx LOOP
        keys := keys || to_jsonb(''::text);
    END LOOP;

    UPDATE config SET value = (urls || to_jsonb(target))::json, updated_at = stamp
        WHERE key = 'openai.api_base_urls';
    UPDATE config SET value = (keys || to_jsonb('$key'::text))::json, updated_at = stamp
        WHERE key = 'openai.api_keys';
    UPDATE config SET value = jsonb_set(
            coalesce(value::jsonb, '{}'::jsonb),
            ARRAY[idx::text],
            jsonb_build_object(
                'enable', true, 'connection_type', 'local',
                'tags', '[]'::jsonb, 'model_ids', '[]'::jsonb,
                'prefix_id', '$prefix'
            ),
            true
        )::json, updated_at = stamp
        WHERE key = 'openai.api_configs';
    UPDATE config SET value = 'true'::json, updated_at = stamp
        WHERE key = 'openai.enable';
END
\$\$;
SQL
}

# 0 changed, 1 nothing to do, 2 the config table could not be read. Idempotent
# by URL, so a connection deleted on purpose comes back - as /v1 always has.
ensure_connection() {
    local url="$1" key="$2" prefix="$3"

    case "$(connection_state "$url" "$key")" in
        absent | current) return 1 ;;
        missing)
            log "Registering $url as an Open WebUI connection"
            if add_connection "$url" "$key" "$prefix"; then
                return 0
            fi
            log "WARNING: failed to register $url"
            return 1
            ;;
        stale)
            log "Stored key for $url does not match the gateway's; correcting it"
            if update_connection_key "$url" "$key"; then
                return 0
            fi
            log "WARNING: failed to correct the key for $url"
            return 1
            ;;
        *)
            log "WARNING: could not read Open WebUI config table; skipping"
            return 2
            ;;
    esac
}

# 170 prompt tokens for the whole schema, against the ~5000 of the built-in tools
# disabled above. Idempotent by URL, so anything changed afterwards in Admin
# Settings > Tools survives.
register_tool_server() {
    psql_owui -q <<SQL
DO \$\$
DECLARE
    servers jsonb;
    stamp   bigint := extract(epoch from now())::bigint;
BEGIN
    SELECT coalesce(value::jsonb, '[]'::jsonb) INTO servers
        FROM config WHERE key = 'tool_server.connections';
    servers := coalesce(servers, '[]'::jsonb);

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(servers) AS s
        WHERE s->>'url' = '$TOOLS_URL'
    ) THEN
        RETURN;
    END IF;

    servers := servers || jsonb_build_object(
        'url',       '$TOOLS_URL',
        'path',      'openapi.json',
        'type',      'openapi',
        -- Unauthenticated: the ai network is internal and this server only reads.
        'auth_type', 'none',
        'key',       '',
        -- access_grants, or has_connection_access makes this admin-only; see
        -- apply_open_access, which patches a connection created before this.
        'config',    jsonb_build_object(
                         'enable', true,
                         'access_grants', \$g\$[{"principal_type": "user", "principal_id": "*", "permission": "read"}]\$g\$::jsonb
                     ),
        'info',      jsonb_build_object(
                         'id',          '$TOOLS_ID',
                         'name',        'Server status',
                         'description', 'Disk, CPU, memory, containers, restarts, errors, backups and tailnet devices'
                     )
    );

    INSERT INTO config (key, value, updated_at)
        VALUES ('tool_server.connections', servers::json, stamp)
        ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
END
\$\$;
SQL
}

# On the workspace entry, so the tool is offered without being ticked per chat.
attach_tool_server() {
    psql_owui -q <<SQL
INSERT INTO model (id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active)
SELECT
    '$LLAMA_MODEL',
    (SELECT id FROM "user" WHERE role = 'admin' ORDER BY created_at LIMIT 1),
    NULL,
    '$LLAMA_MODEL',
    '{"capabilities": {"builtin_tools": false}, "toolIds": ["server:$TOOLS_ID"]}',
    '{}',
    extract(epoch from now())::bigint,
    extract(epoch from now())::bigint,
    true
WHERE EXISTS (SELECT 1 FROM "user" WHERE role = 'admin')
ON CONFLICT (id) DO UPDATE SET
    meta = jsonb_set(
        coalesce(model.meta::jsonb, '{}'::jsonb),
        '{toolIds}',
        coalesce(model.meta::jsonb->'toolIds', '[]'::jsonb) || '["server:$TOOLS_ID"]'::jsonb,
        true
    )::text,
    updated_at = extract(epoch from now())::bigint
WHERE NOT coalesce(model.meta::jsonb->'toolIds', '[]'::jsonb) ? 'server:$TOOLS_ID';
SQL
}

# On the model rather than in ui.prompt_suggestions: the frontend reads
# model.info.meta.suggestion_prompts first and only falls back to the global
# list, and these assume the tool is attached.
#
# Each wording was checked against llama-server with the schema attached - a
# prompt that reads well is not necessarily one this model turns into a call.
# Singular ("est-ce qu'un conteneur est arrêté ?") makes it ask which container,
# and negation ("depuis quand X n'est-il plus en ligne ?") makes it answer with
# nothing at all; both work stated positively and in the plural.
apply_prompt_suggestions() {
    psql_owui -q <<SQL
INSERT INTO model (id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active)
SELECT
    '$LLAMA_MODEL',
    (SELECT id FROM "user" WHERE role = 'admin' ORDER BY created_at LIMIT 1),
    NULL,
    '$LLAMA_MODEL',
    -- toolIds too, or this path recreates the row without the tool the
    -- suggestions depend on.
    jsonb_build_object('capabilities', jsonb_build_object('builtin_tools', false),
                       'toolIds', jsonb_build_array('server:$TOOLS_ID'),
                       'suggestion_prompts', \$j\$$SUGGESTIONS\$j\$::jsonb)::text,
    '{}',
    extract(epoch from now())::bigint,
    extract(epoch from now())::bigint,
    true
WHERE EXISTS (SELECT 1 FROM "user" WHERE role = 'admin')
ON CONFLICT (id) DO UPDATE SET
    meta = jsonb_set(
        coalesce(model.meta::jsonb, '{}'::jsonb),
        '{suggestion_prompts}',
        \$j\$$SUGGESTIONS\$j\$::jsonb,
        true
    )::text,
    updated_at = extract(epoch from now())::bigint;
SQL
}

# For the groups whose work does not fit in one statement; the others write their
# marker as part of theirs, so a failure cannot record them as seeded.
mark_seeded() {
    psql_owui -q -c \
        "INSERT INTO config (key, value, updated_at)
             VALUES ('$1', '$2'::json, extract(epoch from now())::bigint)
             ON CONFLICT (key) DO UPDATE
             SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;"
}

# Every write to the model row is guarded by `WHERE EXISTS (... role = 'admin')`,
# and on a fresh install nobody has signed in yet - see main().
admin_present() {
    psql_owui -tAc "SELECT EXISTS (SELECT 1 FROM \"user\" WHERE role = 'admin');" 2>/dev/null \
        | tr -d '[:space:]'
}

marker_present() {
    psql_owui -tAc \
        "SELECT EXISTS (
             SELECT 1 FROM config WHERE key = '$1' AND value::text = '$2'
         );" 2>/dev/null | tr -d ' \r\n'
}

# Seeded, not enforced: an engine has to be named for the read-aloud button to
# exist at all, but this runs once, so switching back to the browser voice in
# Admin Settings sticks. Per-user choices in Settings > Audio override it anyway.
apply_tts_defaults() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('audio.tts.engine',              '"openai"'::json,         extract(epoch from now())::bigint),
    ('audio.tts.openai.api_base_url', '"$TTS_BASE_URL"'::json,  extract(epoch from now())::bigint),
    ('audio.tts.model',               '"$TTS_VOICE"'::json,     extract(epoch from now())::bigint),
    ('audio.tts.voice',               '"$TTS_VOICE"'::json,     extract(epoch from now())::bigint),
    ('$TTS_MARKER',                   '$TTS_VERSION'::json,     extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL
}

# DEFAULT_LOCALE is PersistentConfig, so compose only reaches an instance that
# has never started; on an existing one the database still holds Open WebUI's
# empty default, which means "follow the browser". Seeded once, like the rest, so
# an admin can set it back to blank.
apply_locale_default() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('ui.default_locale', '"$DEFAULT_LANGUAGE"'::json, extract(epoch from now())::bigint),
    ('$LOCALE_MARKER',    '$LOCALE_VERSION'::json,     extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL
}

# Mirrors the AUDIO_STT_* variables on the open-webui service, which are
# PersistentConfig and so cover only a fresh install - an existing database is
# what this function is here for. Seeded, not enforced, like the TTS block above.
#
# An empty engine selects the built-in whisper, which runs inside the open-webui
# container: `base`, 20.2% WER on read French, and no room under that container's
# 1g for anything better. See the parakeet service in compose.yaml.
apply_stt_defaults() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('audio.stt.engine',              '"openai"'::json,        extract(epoch from now())::bigint),
    ('audio.stt.openai.api_base_url', '"$STT_BASE_URL"'::json, extract(epoch from now())::bigint),
    ('audio.stt.model',               '"$STT_MODEL"'::json,    extract(epoch from now())::bigint),
    ('$STT_MARKER',                   '$STT_VERSION'::json,    extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL
}

# base_model_id IS NULL restricts this to a base-model override, the shape the
# Ollama-era row has, so a model someone built on top of a base is left alone
# even if the id ever collided. Chats keep their own copy of the model id and
# there is no foreign key here, so old conversations stay readable.
drop_stale_ollama_model() {
    psql_owui -q <<SQL
DELETE FROM model WHERE id = '$STALE_MODEL_ID' AND base_model_id IS NULL;
SQL
}

# DEFAULT_USER_ROLE is PersistentConfig: the value in compose.yaml only applies
# to an instance that has never started, so the database still holds "pending".
# Accounts already parked had passed Authelia, so release them too.
#
# The role alone is not enough; both grants below undo an admin-only default:
#   - get_filtered_models keeps a model that has a workspace row only for its
#     owner or a named grantee, and that row belongs to the admin - so every
#     other account would get an empty model picker.
#   - has_connection_access treats a tool server with no access_grants as
#     admin-only, so a normal user would get invented answers, not tool calls.
# ('user', '*', 'read') is the public-read shape the code documents, and stays
# revocable in the UI.
#
# One transaction, with the marker written last: psql autocommits statement by
# statement, so committing the marker first - as this used to - would record the
# group as seeded even when the grant below failed, and the grants would then be
# skipped forever behind a single WARNING.
apply_open_access() {
    psql_owui -q <<SQL
BEGIN;

INSERT INTO config (key, value, updated_at) VALUES
    ('ui.default_user_role', '"user"'::json, extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

UPDATE "user" SET role = 'user' WHERE role = 'pending';

INSERT INTO access_grant
    (id, resource_type, resource_id, principal_type, principal_id, permission, created_at)
VALUES
    ('pi-pcloud-model-public-read', 'model', '$LLAMA_MODEL', 'user', '*', 'read',
     extract(epoch from now())::bigint)
ON CONFLICT (resource_type, resource_id, principal_type, principal_id, permission)
    DO NOTHING;

UPDATE config SET
    value = (
        SELECT jsonb_agg(
            CASE WHEN server->>'url' = '$TOOLS_URL'
                 THEN jsonb_set(
                          server,
                          '{config,access_grants}',
                          \$g\$[{"principal_type": "user", "principal_id": "*", "permission": "read"}]\$g\$::jsonb,
                          true
                      )
                 ELSE server
            END
        )
        FROM jsonb_array_elements(config.value::jsonb) AS server
    )::json,
    updated_at = extract(epoch from now())::bigint
WHERE key = 'tool_server.connections'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(config.value::jsonb) AS server
      WHERE server->>'url' = '$TOOLS_URL'
        AND coalesce(jsonb_array_length(server->'config'->'access_grants'), 0) = 0
  );

INSERT INTO config (key, value, updated_at) VALUES
    ('$ACCESS_MARKER', '$ACCESS_VERSION'::json, extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

COMMIT;
SQL
}

# Open WebUI fires an extra, invisible LLM call per message for each of these:
# a chat title, chat tags, follow-up suggestions, a search query rewrite. Against
# a cloud API that is free; against a Pi generating ~10 tok/s it multiplies the
# wait for the answer the user is actually looking at, several times over, all
# competing for the same three CPU threads. Off by default here.
apply_task_defaults() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('task.title.enable',                'false'::json,          extract(epoch from now())::bigint),
    ('task.tags.enable',                 'false'::json,          extract(epoch from now())::bigint),
    ('task.follow_up.enable',            'false'::json,          extract(epoch from now())::bigint),
    ('task.query.search.enable',         'false'::json,          extract(epoch from now())::bigint),
    ('task.query.retrieval.enable',      'false'::json,          extract(epoch from now())::bigint),
    ('task.autocomplete.enable',         'false'::json,          extract(epoch from now())::bigint),
    ('memories.background_review.enable','false'::json,          extract(epoch from now())::bigint),
    ('task.model.default',               '"$LLAMA_MODEL"'::json, extract(epoch from now())::bigint),
    ('$DEFAULTS_MARKER',                 '$DEFAULTS_VERSION'::json, extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL
}

# Built-in tools (time, memory, chats, notes, knowledge, channels) are on by
# default for every model, and their schemas go into the prompt of every message
# sent from the browser - about 5000 tokens, ~3 minutes of prompt processing on
# this CPU before the model starts writing. Attaching tools to a chat explicitly
# still works.
#
# Global, not per model: utils/models.py merges this into every model and lets a
# workspace row override it, so it covers the path routes' catalogues as they
# change. Open WebUI reads none of the capability metadata providers publish, so
# a default for all of them is the only lever there is.
apply_global_model_metadata() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at)
VALUES ('models.default_metadata',
        '{"capabilities": {"builtin_tools": false}}'::json,
        extract(epoch from now())::bigint)
-- Concatenation at both levels, not jsonb_set: create_missing only creates the
-- *last* element of the path, so on a stored '{}' - which is what Open WebUI
-- ships - a jsonb_set of '{capabilities,builtin_tools}' returns the input
-- untouched and reports success. Merging preserves any other capability set
-- here by hand.
ON CONFLICT (key) DO UPDATE
    SET value = (
            coalesce(config.value::jsonb, '{}'::jsonb)
            || jsonb_build_object('capabilities',
                   coalesce(config.value::jsonb -> 'capabilities', '{}'::jsonb)
                   || jsonb_build_object('builtin_tools', false))
        )::json,
        updated_at = EXCLUDED.updated_at;
SQL
}

main() {
    changed=0

    if ! container_is_running "pi-postgres"; then
        log "postgres is not running; skipping Open WebUI bootstrap"
        return 0
    fi

    wait_for_health_warning "pi-open-webui" 60 2 || true

    _key="$(read_api_key "$GATEWAY_KEY_FILE")" || _key=""
    _agent_key="$(read_api_key "$AGENT_KEY_FILE")" || _agent_key=""
    if [ -z "$_key" ]; then
        log "WARNING: no readable agentgateway LLM API key; leaving the connections alone"
    else
        ensure_connection "$GATEWAY_URL" "$_key" "" || _rc=$?
        _rc="${_rc:-0}"
        if [ "$_rc" -eq 2 ]; then
            return 0
        fi
        if [ "$_rc" -eq 0 ]; then
            changed=1
        fi
        unset _rc

        # No model_ids filter, deliberately: naming models here would be the
        # hardcoded list these routes exist to avoid. Groq's catalogue therefore
        # arrives whole, transcription and speech models included. Filter in
        # Admin Settings; this leaves what is set there alone.
        if [ -n "$_agent_key" ]; then
            for _route in "groq:$GROQ_URL" "openrouter:$OPENROUTER_URL"; do
                ensure_connection "${_route#*:}" "$_agent_key" "${_route%%:*}" || _rc=$?
                _rc="${_rc:-0}"
                if [ "$_rc" -eq 0 ]; then
                    changed=1
                fi
                unset _rc
            done
        fi
    fi

    if [ "$(marker_present "$DEFAULTS_MARKER" "$DEFAULTS_VERSION")" = "f" ]; then
        log "Seeding low-latency defaults (title/tags/follow-up generation off)"
        if apply_task_defaults; then
            changed=1
        else
            log "WARNING: failed to seed Open WebUI defaults"
        fi
    fi

    if [ "$(marker_present "$LOCALE_MARKER" "$LOCALE_VERSION")" = "f" ]; then
        log "Setting the default interface language to $DEFAULT_LANGUAGE"
        if apply_locale_default; then
            changed=1
        else
            log "WARNING: failed to seed the Open WebUI default language"
        fi
    fi

    if [ "$(marker_present "$STALE_MODEL_MARKER" "$STALE_MODEL_VERSION")" = "f" ]; then
        log "Removing the leftover Ollama-era model row ($STALE_MODEL_ID)"
        if drop_stale_ollama_model && mark_seeded "$STALE_MODEL_MARKER" "$STALE_MODEL_VERSION"; then
            changed=1
        else
            log "WARNING: failed to remove the stale $STALE_MODEL_ID model row"
        fi
    fi

    if [ "$(marker_present "$TTS_MARKER" "$TTS_VERSION")" = "f" ]; then
        log "Pointing text-to-speech at Piper ($TTS_VOICE)"
        if apply_tts_defaults; then
            changed=1
        else
            log "WARNING: failed to seed Open WebUI text-to-speech settings"
        fi
    fi

    if [ "$(marker_present "$STT_MARKER" "$STT_VERSION")" = "f" ]; then
        log "Pointing speech-to-text at Parakeet ($STT_MODEL)"
        if apply_stt_defaults; then
            changed=1
        else
            log "WARNING: failed to seed Open WebUI speech-to-text settings"
        fi
    fi

    # Everything below writes the model's workspace row or grants access to it,
    # and every one of those statements is guarded by `WHERE EXISTS (... role =
    # 'admin')` - so before the first SSO login they would write nothing, exit 0,
    # and be marked as seeded forever.
    if [ "$(admin_present)" != "t" ]; then
        log "no Open WebUI account yet; leaving the rest to the next run"
        [ "$changed" = "1" ] || return 0
        log "Restarting open-webui to pick up the new configuration"
        compose restart open-webui >/dev/null 2>&1 || log "WARNING: could not restart open-webui"
        wait_for_health_warning "pi-open-webui" 90 2 || true
        return 0
    fi

    if [ "$(marker_present "$GLOBAL_META_MARKER" "$GLOBAL_META_VERSION")" = "f" ]; then
        log "Turning the built-in tools off on every model (~5000 prompt tokens each)"
        if apply_global_model_metadata && mark_seeded "$GLOBAL_META_MARKER" "$GLOBAL_META_VERSION"; then
            changed=1
        else
            log "WARNING: failed to seed the global model metadata"
        fi
    fi

    if [ "$(marker_present "$TOOLS_MARKER" "$TOOLS_VERSION")" = "f" ]; then
        log "Registering the system-status tool server and attaching it to $LLAMA_MODEL"
        if register_tool_server && attach_tool_server && mark_seeded "$TOOLS_MARKER" "$TOOLS_VERSION"; then
            changed=1
        else
            log "WARNING: failed to register the system-status tool server"
        fi
    fi

    if [ "$(marker_present "$ACCESS_MARKER" "$ACCESS_VERSION")" = "f" ]; then
        log "Granting Open WebUI access to every SSO user (no admin approval)"
        if apply_open_access; then
            changed=1
        else
            log "WARNING: failed to open Open WebUI access to every SSO user"
        fi
    fi

    if [ "$(marker_present "$SUGGESTIONS_MARKER" "$SUGGESTIONS_VERSION")" = "f" ]; then
        log "Seeding the new-chat suggestions that exercise the status tool"
        if apply_prompt_suggestions && mark_seeded "$SUGGESTIONS_MARKER" "$SUGGESTIONS_VERSION"; then
            changed=1
        else
            log "WARNING: failed to seed the Open WebUI prompt suggestions"
        fi
    fi

    [ "$changed" = "1" ] || return 0

    log "Restarting open-webui to pick up the new configuration"
    compose restart open-webui >/dev/null 2>&1 || log "WARNING: could not restart open-webui"
    wait_for_health_warning "pi-open-webui" 90 2 || true
}

main "$@"
