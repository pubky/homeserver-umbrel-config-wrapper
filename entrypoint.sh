#!/bin/sh
set -e

# Ensure /data directory exists
mkdir -p /data

# Cloudflare Tunnel: read domain from dashboard-written file if present (overrides env)
if [ -f /etc/pubky-cloudflare/domain ] && [ -s /etc/pubky-cloudflare/domain ]; then
  CLOUDFLARE_DOMAIN=$(cat /etc/pubky-cloudflare/domain | tr -d '\n\r')
  export CLOUDFLARE_DOMAIN
fi

# Generate config.toml if it doesn't exist
if [ ! -f /data/config.toml ]; then
  # Validate required environment variables
  if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: POSTGRES_PASSWORD environment variable is required" >&2
    exit 1
  fi

  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "ERROR: ADMIN_PASSWORD environment variable is required" >&2
    exit 1
  fi

  # Determine PUBLIC_IP: use env var, or try to detect, or use default
  if [ -n "$PUBLIC_IP" ]; then
    DETECTED_PUBLIC_IP="$PUBLIC_IP"
  else
    # Try to get the device's local IP (works in Docker networks)
    DETECTED_PUBLIC_IP=$(hostname -i 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    if [ -z "$DETECTED_PUBLIC_IP" ]; then
      DETECTED_PUBLIC_IP="127.0.0.1"
    fi
  fi

  # Determine ICANN_DOMAIN: Cloudflare Tunnel takes precedence, then env, then Umbrel device name, then default
  DETECTED_PUBLIC_ICANN_HTTP_PORT=""
  if [ -n "$CLOUDFLARE_DOMAIN" ]; then
    DETECTED_ICANN_DOMAIN="$CLOUDFLARE_DOMAIN"
    DETECTED_PUBLIC_ICANN_HTTP_PORT="443"
  elif [ -n "$ICANN_DOMAIN" ]; then
    DETECTED_ICANN_DOMAIN="$ICANN_DOMAIN"
  elif [ -n "$DEVICE_DOMAIN_NAME" ]; then
    DETECTED_ICANN_DOMAIN="$DEVICE_DOMAIN_NAME"
  else
    DETECTED_ICANN_DOMAIN="localhost"
  fi

  # Warn if using defaults that won't work for external access (skip when using Cloudflare)
  if [ -z "$CLOUDFLARE_DOMAIN" ] && { [ "$DETECTED_PUBLIC_IP" = "127.0.0.1" ] || [ "$DETECTED_ICANN_DOMAIN" = "localhost" ]; }; then
    echo "WARNING: Using default values for public_ip ($DETECTED_PUBLIC_IP) and icann_domain ($DETECTED_ICANN_DOMAIN)." >&2
    echo "WARNING: Set PUBLIC_IP and ICANN_DOMAIN, or use Cloudflare Tunnel (CLOUDFLARE_DOMAIN + CLOUDFLARE_TUNNEL_TOKEN)." >&2
  fi

  export POSTGRES_PASSWORD ADMIN_PASSWORD DETECTED_PUBLIC_IP DETECTED_ICANN_DOMAIN
  envsubst < /usr/local/share/config.toml.template > /data/config.toml

  if [ -n "$DETECTED_PUBLIC_ICANN_HTTP_PORT" ]; then
    sed -i "/^icann_domain = /a public_icann_http_port = $DETECTED_PUBLIC_ICANN_HTTP_PORT" /data/config.toml
  fi

  chmod 644 /data/config.toml || true
  chown homeserver:homeserver /data/config.toml || true
fi

# If config already exists and CLOUDFLARE_DOMAIN is set (e.g. from dashboard), update [pkdns]
if [ -f /data/config.toml ] && [ -n "$CLOUDFLARE_DOMAIN" ]; then
  if grep -q '^icann_domain = ' /data/config.toml; then
    sed -i "s|^icann_domain = .*|icann_domain = \"$CLOUDFLARE_DOMAIN\"|" /data/config.toml
  fi
  if ! grep -q '^public_icann_http_port = ' /data/config.toml; then
    sed -i "/^icann_domain = /a public_icann_http_port = 443" /data/config.toml
  else
    sed -i 's/^public_icann_http_port = .*/public_icann_http_port = 443/' /data/config.toml
  fi
  chown homeserver:homeserver /data/config.toml 2>/dev/null || true
fi

# Preview mode prerequisite: the cloudflared-preview container (distroless,
# UID 65532) must be able to create its logfile in the preview dir. This
# wrapper runs as root at every app start, before the homeserver, so it owns
# that preparation (the dashboard's entrypoint runs too late on first boot).
if [ -d /etc/pubky-cloudflare ]; then
  mkdir -p /etc/pubky-cloudflare/preview 2>/dev/null || true
  chown 65532:65532 /etc/pubky-cloudflare/preview 2>/dev/null || true
  chmod 770 /etc/pubky-cloudflare/preview 2>/dev/null || true
fi

# Preview mode (dashboard "Preview" feature): a Cloudflare Quick Tunnel whose
# random *.trycloudflare.com URL is published as the homeserver's domain.
# The cloudflared-preview compose service (gated on the same testdrive.env
# file via env_file) starts before this wrapper and writes its log to
# preview/quick.log; the assigned URL appears there within ~10s. Each app
# restart yields a NEW random URL, so this runs on every start.
# Precedence: a real domain (CLOUDFLARE_DOMAIN above) always wins.
if [ -f /data/config.toml ] && [ -z "$CLOUDFLARE_DOMAIN" ]; then
  if [ -f /etc/pubky-cloudflare/testdrive.env ]; then
    PREVIEW_URL=""
    for i in $(seq 1 30); do
      # tail -1: the logfile appends across container restarts; the last
      # non-API trycloudflare URL is the current one.
      PREVIEW_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /etc/pubky-cloudflare/preview/quick.log 2>/dev/null | grep -v '^https://api\.' | tail -1)
      [ -n "$PREVIEW_URL" ] && break
      sleep 1
    done
    if [ -n "$PREVIEW_URL" ]; then
      PREVIEW_DOMAIN="${PREVIEW_URL#https://}"
      echo "Preview mode: publishing $PREVIEW_DOMAIN as icann_domain"
      sed -i "s|^icann_domain = .*|icann_domain = \"$PREVIEW_DOMAIN\"|" /data/config.toml
      if ! grep -q '^public_icann_http_port = ' /data/config.toml; then
        sed -i "/^icann_domain = /a public_icann_http_port = 443" /data/config.toml
      else
        sed -i 's/^public_icann_http_port = .*/public_icann_http_port = 443/' /data/config.toml
      fi
      chown homeserver:homeserver /data/config.toml 2>/dev/null || true
    else
      echo "WARNING: preview mode enabled but no quick-tunnel URL appeared within 30s; leaving icann_domain unchanged" >&2
    fi
  elif grep -q '^icann_domain = ".*\.trycloudflare\.com"' /data/config.toml; then
    # Preview was disabled: reset the stale random domain so the published
    # record stops pointing at a dead URL.
    echo "Preview mode disabled: resetting stale trycloudflare icann_domain to localhost"
    sed -i 's|^icann_domain = .*|icann_domain = "localhost"|' /data/config.toml
    sed -i '/^public_icann_http_port = /d' /data/config.toml
    chown homeserver:homeserver /data/config.toml 2>/dev/null || true
  fi
fi

# Optimize chown: only run if ownership change is needed
# Check if /data is owned by homeserver user
if [ "$(stat -c '%U:%G' /data 2>/dev/null || stat -f '%Su:%Sg' /data 2>/dev/null)" != "homeserver:homeserver" ]; then
  # Only chown if ownership is different
  chown -R homeserver:homeserver /data || true
fi
