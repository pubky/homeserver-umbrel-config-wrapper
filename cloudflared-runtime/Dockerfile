# Thin runtime around the official cloudflared binary so ONE compose service
# can select its tunnel mode (local config.yml / token / preview) at runtime,
# replacing three services of which two always crash-looped as a file gate.
#
# Supply-chain stance: the cloudflared binary is copied from the exact same
# digest-pinned official image the app store compose pins today; this image
# adds only a pinned alpine base and a POSIX entrypoint. Adopting it is
# gated on an explicit team decision (see README.md).
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

# Statically-linked binary, same digest the store's docker-compose.yml pins
# for its cloudflared services (multi-arch index, amd64 + arm64).
COPY --from=docker.io/cloudflare/cloudflared:2026.5.2@sha256:12ff5c6992a9863db4da270746af7c244bcaee49353039af8104268a18d6c4f0 \
  /usr/local/bin/cloudflared /usr/local/bin/cloudflared

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh \
  && addgroup -g 65532 -S nonroot \
  && adduser -u 65532 -S -G nonroot -h /home/nonroot nonroot

# Match the official image, which runs as 65532:65532 (distroless nonroot).
# The config wrapper already prepares file/dir perms for this UID on every
# start, so the existing data dir keeps working unchanged.
USER 65532:65532

# No HEALTHCHECK: cloudflared exposes no health endpoint unless --metrics is
# enabled, and the no-mode-configured waiting loop is healthy by design, so
# any cheap probe would either lie or need network assumptions.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
