FROM alpine:3.20
RUN apk add --no-cache envsubst

RUN addgroup -S homeserver && adduser -S homeserver -G homeserver

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config.toml.template /usr/local/share/config.toml.template
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chmod 644 /usr/local/share/config.toml.template

WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
