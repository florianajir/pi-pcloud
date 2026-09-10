# Extends the official beszel-agent image with smartmontools for S.M.A.R.T. support.
# The agent binary is statically compiled Go, so it runs fine on Alpine.
# Kept in lockstep with the beszel hub tag in compose.yaml — bump both together.
FROM henrygd/beszel-agent:0.19.0 AS upstream

FROM alpine:3.24
# Pinned to the major, for the reason config/backrest/Dockerfile spells out:
# alpine:3.24 above is the reproducibility boundary, and an exact pin inside it
# only turns a patch bump into a failed build.
RUN apk add --no-cache smartmontools=~7
COPY --from=upstream /agent /agent
VOLUME ["/var/lib/beszel-agent"]
ENTRYPOINT ["/agent"]
