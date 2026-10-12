FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache envsubst

RUN addgroup -S homeserver && adduser -S homeserver -G homeserver

# The official cloudflared binary, for the app's tunnel service (tunnel.sh).
# Copied unmodified from the upstream image at a pinned digest (multi-arch
# index, amd64 + arm64); it is a static binary and runs on alpine as is.
COPY --from=cloudflare/cloudflared:2026.5.2@sha256:12ff5c6992a9863db4da270746af7c244bcaee49353039af8104268a18d6c4f0 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY tunnel.sh /usr/local/bin/tunnel.sh
COPY config.toml.template /usr/local/share/config.toml.template
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tunnel.sh && \
    chmod 644 /usr/local/share/config.toml.template

WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
