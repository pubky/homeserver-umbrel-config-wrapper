FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache envsubst

RUN addgroup -S homeserver && adduser -S homeserver -G homeserver

# The official cloudflared binary, for the app's tunnel service (tunnel.sh).
# Copied unmodified from the upstream image at a pinned digest (multi-arch
# index, amd64 + arm64); it is a static binary and runs on alpine as is.
COPY --from=cloudflare/cloudflared:2026.10.3@sha256:faa8e0a1475f137c910be6025f43c8e4092fdd35461b31e19fd1390657a1ff39 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY tunnel.sh /usr/local/bin/tunnel.sh
COPY config.toml.template /usr/local/share/config.toml.template
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tunnel.sh && \
    chmod 644 /usr/local/share/config.toml.template

WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
