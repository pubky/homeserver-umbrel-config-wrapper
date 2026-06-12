#!/bin/sh
set -e

# Paths are env-overridable so the test harness (tests/run.sh) can exercise
# this script on a plain host; the container always uses the defaults.
DATA_DIR=${DATA_DIR:-/data}
CF_DIR=${CLOUDFLARE_DIR:-/etc/pubky-cloudflare}
CONFIG_TEMPLATE=${CONFIG_TEMPLATE:-/usr/local/share/config.toml.template}
PREVIEW_WAIT_SECS=${PREVIEW_WAIT_SECS:-45}
CONFIG="$DATA_DIR/config.toml"
PREVIEW_DIR="$CF_DIR/preview"

# Epoch at script start: a preview URL whose log line is older than this
# (minus a grace period) belongs to a previous boot and must not be
# re-published.
WRAPPER_START=$(date +%s)

# Parse an ISO8601 timestamp (e.g. 2026-06-12T05:11:22Z) to epoch seconds.
# Tries busybox date first (-D strptime format), then GNU date (for the
# host-side test harness). Prints nothing and returns nonzero on garbage.
iso_to_epoch() {
  _iso=$(printf '%s' "$1" | cut -c1-19)
  date -u -D "%Y-%m-%dT%H:%M:%S" -d "$_iso" +%s 2>/dev/null \
    || date -u -d "$_iso" +%s 2>/dev/null
}

# Print the newest quick-tunnel URL in the logfile ($1) whose log line is
# recent enough to belong to this boot: timestamp >= WRAPPER_START - 15s
# (grace because cloudflared-preview has no depends_on ordering and can win
# the start race, logging its fresh URL before this script's first instant).
# cloudflared's --logfile lines are JSON with a "time" field; a leading bare
# timestamp (console format) is handled too. Lines whose timestamp cannot be
# found or parsed are not acceptable.
newest_fresh_url() {
  [ -f "$1" ] || return 0
  _cutoff=$((WRAPPER_START - 15))
  grep 'trycloudflare\.com' "$1" 2>/dev/null | while IFS= read -r _line; do
    _url=$(printf '%s\n' "$_line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | grep -v '^https://api\.' | head -n1)
    [ -n "$_url" ] || continue
    _ts=$(printf '%s\n' "$_line" | sed -n 's/.*"time":"\([^"]*\)".*/\1/p')
    if [ -z "$_ts" ]; then
      _ts=$(printf '%s\n' "$_line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}' || true)
    fi
    [ -n "$_ts" ] || continue
    _epoch=$(iso_to_epoch "$_ts") || continue
    [ -n "$_epoch" ] || continue
    [ "$_epoch" -ge "$_cutoff" ] && printf '%s\n' "$_url"
  done | tail -n 1
}

# Ensure data directory exists
mkdir -p "$DATA_DIR"

# Cloudflare Tunnel: read domain from dashboard-written file if present (overrides env)
if [ -f "$CF_DIR/domain" ] && [ -s "$CF_DIR/domain" ]; then
  CLOUDFLARE_DOMAIN=$(tr -d '\n\r' < "$CF_DIR/domain")
  export CLOUDFLARE_DOMAIN
fi

# Domain safety: the value is interpolated into sed expressions and TOML
# below, so anything outside a strict hostname charset is rejected loudly
# and the boot proceeds as if no domain were set.
if [ -n "$CLOUDFLARE_DOMAIN" ]; then
  case "$CLOUDFLARE_DOMAIN" in
    *[!A-Za-z0-9.-]*)
      echo "WARNING: domain '$CLOUDFLARE_DOMAIN' contains characters outside [A-Za-z0-9.-]; ignoring it (check $CF_DIR/domain)" >&2
      CLOUDFLARE_DOMAIN=""
      ;;
  esac
fi

# Treat a zero-byte config.toml as absent: an interrupted first boot must
# not brick the install. (A partially-written non-empty file cannot be told
# apart from user edits, so only the empty case is healed.)
if [ -f "$CONFIG" ] && [ ! -s "$CONFIG" ]; then
  echo "WARNING: $CONFIG is empty (interrupted first boot?); regenerating" >&2
  rm -f "$CONFIG"
fi

# Generate config.toml if it doesn't exist
if [ ! -f "$CONFIG" ]; then
  # Validate required environment variables
  if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: POSTGRES_PASSWORD environment variable is required" >&2
    exit 1
  fi

  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "ERROR: ADMIN_PASSWORD environment variable is required" >&2
    exit 1
  fi

  # [pkdns] public_ip: only publish an address the operator explicitly
  # provided. Auto-detection (hostname -i) yields the docker-internal 172.x
  # address, which is garbage in the DHT. When the line is omitted the
  # homeserver falls back to its built-in default (127.0.0.1).
  if [ -n "$PUBLIC_IP" ]; then
    PUBLIC_IP_LINE="public_ip = \"$PUBLIC_IP\""
  else
    PUBLIC_IP_LINE="# public_ip omitted: set the PUBLIC_IP env var to publish a reachable address"
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
  if [ -z "$CLOUDFLARE_DOMAIN" ] && [ "$DETECTED_ICANN_DOMAIN" = "localhost" ]; then
    echo "WARNING: Using default icann_domain ($DETECTED_ICANN_DOMAIN)." >&2
    echo "WARNING: Set ICANN_DOMAIN, or use Cloudflare Tunnel (CLOUDFLARE_DOMAIN + CLOUDFLARE_TUNNEL_TOKEN)." >&2
  fi

  export POSTGRES_PASSWORD ADMIN_PASSWORD PUBLIC_IP_LINE DETECTED_ICANN_DOMAIN
  # Render atomically (tmp + mv): an interrupted boot must never leave a
  # truncated config.toml that the once-only guard above treats as final.
  envsubst < "$CONFIG_TEMPLATE" > "$CONFIG.tmp"

  if [ -n "$DETECTED_PUBLIC_ICANN_HTTP_PORT" ]; then
    sed -i "/^icann_domain = /a public_icann_http_port = $DETECTED_PUBLIC_ICANN_HTTP_PORT" "$CONFIG.tmp"
  fi

  chmod 644 "$CONFIG.tmp" 2>/dev/null || true
  chown homeserver:homeserver "$CONFIG.tmp" 2>/dev/null || true
  mv "$CONFIG.tmp" "$CONFIG"
fi

# If config already exists and CLOUDFLARE_DOMAIN is set (e.g. from dashboard), update [pkdns]
if [ -f "$CONFIG" ] && [ -n "$CLOUDFLARE_DOMAIN" ]; then
  if grep -q '^icann_domain = ' "$CONFIG"; then
    sed -i "s|^icann_domain = .*|icann_domain = \"$CLOUDFLARE_DOMAIN\"|" "$CONFIG"
  fi
  if ! grep -q '^public_icann_http_port = ' "$CONFIG"; then
    sed -i "/^icann_domain = /a public_icann_http_port = 443" "$CONFIG"
  else
    sed -i 's/^public_icann_http_port = .*/public_icann_http_port = 443/' "$CONFIG"
  fi
  # One-time heal: old installs auto-detected the docker-internal address
  # into public_ip at first generation. Comment it out so the install stops
  # publishing an unroutable IP to the DHT (homeserver default takes over).
  if grep -Eq '^public_ip = "(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' "$CONFIG"; then
    echo "Healing config: commenting out docker-internal public_ip left by an old install"
    sed -i 's|^public_ip = |# public_ip = |' "$CONFIG"
  fi
  chown homeserver:homeserver "$CONFIG" 2>/dev/null || true
fi

# A real domain supersedes preview mode: drop a leftover marker so the
# preview tunnel stops being requested with stale intent.
if [ -n "$CLOUDFLARE_DOMAIN" ] && [ -f "$CF_DIR/testdrive.env" ]; then
  echo "Cloudflare domain configured: removing leftover preview marker $CF_DIR/testdrive.env"
  rm -f "$CF_DIR/testdrive.env"
fi

# Preview mode prerequisite: the cloudflared-preview container (distroless,
# UID 65532) must be able to create its logfile in the preview dir. This
# wrapper runs as root at every app start, before the homeserver, so it owns
# that preparation (the dashboard's entrypoint runs too late on first boot).
if [ -d "$CF_DIR" ]; then
  mkdir -p "$PREVIEW_DIR" 2>/dev/null || true
  chown 65532:65532 "$PREVIEW_DIR" 2>/dev/null || true
  # 777, not 770: the cloudflared-preview container (65532) writes the log,
  # the dashboard (nextjs 1001) reads it back. Nothing secret lives here -
  # the only content is the tunnel's own log with its public URL.
  chmod 777 "$PREVIEW_DIR" 2>/dev/null || true
fi

# Preview mode (dashboard "Preview" feature): a Cloudflare Quick Tunnel whose
# random *.trycloudflare.com URL is published as the homeserver's domain.
# The cloudflared-preview compose service (gated on the same testdrive.env
# file via env_file) writes its log to preview/quick.log; the assigned URL
# appears there within ~10s. Each app restart yields a NEW random URL, so
# this runs on every start. Acceptance is by log line timestamp (see
# newest_fresh_url above), not by file offset: the logfile appends across
# restarts and still contains the previous boot's (now dead) URL.
# Precedence: a real domain (CLOUDFLARE_DOMAIN above) always wins.
if [ -f "$CONFIG" ] && [ -z "$CLOUDFLARE_DOMAIN" ]; then
  if [ -f "$CF_DIR/testdrive.env" ]; then
    LOG="$PREVIEW_DIR/quick.log"
    PREVIEW_URL=""
    for i in $(seq 1 "$PREVIEW_WAIT_SECS"); do
      PREVIEW_URL=$(newest_fresh_url "$LOG")
      [ -n "$PREVIEW_URL" ] && break
      sleep 1
    done
    if [ -n "$PREVIEW_URL" ]; then
      PREVIEW_DOMAIN="${PREVIEW_URL#https://}"
      echo "Preview mode: publishing $PREVIEW_DOMAIN as icann_domain"
      sed -i "s|^icann_domain = .*|icann_domain = \"$PREVIEW_DOMAIN\"|" "$CONFIG"
      if ! grep -q '^public_icann_http_port = ' "$CONFIG"; then
        sed -i "/^icann_domain = /a public_icann_http_port = 443" "$CONFIG"
      else
        sed -i 's/^public_icann_http_port = .*/public_icann_http_port = 443/' "$CONFIG"
      fi
      chown homeserver:homeserver "$CONFIG" 2>/dev/null || true
      # Handshake for the dashboard: the URL this boot actually published,
      # written atomically and world-readable.
      printf '%s\n' "$PREVIEW_URL" > "$PREVIEW_DIR/published.tmp"
      chmod 644 "$PREVIEW_DIR/published.tmp" 2>/dev/null || true
      mv "$PREVIEW_DIR/published.tmp" "$PREVIEW_DIR/published"
    else
      echo "WARNING: preview mode enabled but no fresh quick-tunnel URL appeared within ${PREVIEW_WAIT_SECS}s" >&2
      # Never leave a dead previous-boot URL published.
      rm -f "$PREVIEW_DIR/published" 2>/dev/null || true
      if grep -q '^icann_domain = ".*\.trycloudflare\.com"' "$CONFIG"; then
        echo "WARNING: resetting stale trycloudflare icann_domain to localhost" >&2
        sed -i 's|^icann_domain = .*|icann_domain = "localhost"|' "$CONFIG"
        sed -i '/^public_icann_http_port = /d' "$CONFIG"
        chown homeserver:homeserver "$CONFIG" 2>/dev/null || true
      fi
    fi
  elif grep -q '^icann_domain = ".*\.trycloudflare\.com"' "$CONFIG"; then
    # Preview was disabled: reset the stale random domain so the published
    # record stops pointing at a dead URL.
    echo "Preview mode disabled: resetting stale trycloudflare icann_domain to localhost"
    sed -i 's|^icann_domain = .*|icann_domain = "localhost"|' "$CONFIG"
    sed -i '/^public_icann_http_port = /d' "$CONFIG"
    chown homeserver:homeserver "$CONFIG" 2>/dev/null || true
  fi
fi

# Preview not enabled: drop the handshake file and the logfile. The logfile
# otherwise appends forever (incl. crash-loop error noise on installs that
# never enable preview); removal is safe because the preview service only
# meaningfully runs when testdrive.env exists.
if [ ! -f "$CF_DIR/testdrive.env" ]; then
  rm -f "$PREVIEW_DIR/published" "$PREVIEW_DIR/quick.log" 2>/dev/null || true
fi

# Optimize chown: only run if ownership change is needed
# Check if data dir is owned by homeserver user
if [ "$(stat -c '%U:%G' "$DATA_DIR" 2>/dev/null || stat -f '%Su:%Sg' "$DATA_DIR" 2>/dev/null)" != "homeserver:homeserver" ]; then
  # Only chown if ownership is different
  chown -R homeserver:homeserver "$DATA_DIR" 2>/dev/null || true
fi
