FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache envsubst

RUN addgroup -S homeserver && adduser -S homeserver -G homeserver

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config.toml.template /usr/local/share/config.toml.template
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chmod 644 /usr/local/share/config.toml.template

WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
