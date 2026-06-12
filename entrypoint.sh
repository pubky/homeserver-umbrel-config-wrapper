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

# Version of the config template this wrapper ships. Stamped into config.toml
# as a comment at generation; migrate_config below brings older files up to
# date. Bump this when the template changes in a way existing installs must
# pick up, and add a numbered step to migrate_config.
TEMPLATE_VERSION=1

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

# Migration framework: config.toml is generated once and survives app
# updates, so template changes never reach existing installs on their own.
# The file carries a "# pubky-wrapper-template-version: N" stamp (absent
# means 0); this runs the numbered steps from the stamped version up to
# TEMPLATE_VERSION, then rewrites stamp + file atomically (tmp + mv).
# To add a migration: bump TEMPLATE_VERSION and add a case branch.
migrate_config() {
  [ -f "$CONFIG" ] || return 0
  _ver=$(sed -n 's/^# pubky-wrapper-template-version:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG" | head -n 1)
  [ -n "$_ver" ] || _ver=0
  [ "$_ver" -ge "$TEMPLATE_VERSION" ] && return 0
  echo "Migrating config.toml from template version $_ver to $TEMPLATE_VERSION"
  cp "$CONFIG" "$CONFIG.tmp"
  while [ "$_ver" -lt "$TEMPLATE_VERSION" ]; do
    _ver=$((_ver + 1))
    case "$_ver" in
      1)
        # v1: old installs auto-detected the docker-internal address into
        # public_ip at first generation, publishing an unroutable IP to the
        # DHT. Comment it out; the homeserver's built-in default takes over.
        if grep -Eq '^public_ip[[:space:]]*=[[:space:]]*"(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' "$CONFIG.tmp"; then
          echo "Migration 1: commenting out docker-internal public_ip"
          sed -i 's|^\(public_ip[[:space:]]*=\)|# \1|' "$CONFIG.tmp"
        fi
        ;;
    esac
  done
  if grep -q '^# pubky-wrapper-template-version:' "$CONFIG.tmp"; then
    sed -i "s|^# pubky-wrapper-template-version:.*|# pubky-wrapper-template-version: $_ver|" "$CONFIG.tmp"
  else
    { printf '# pubky-wrapper-template-version: %s\n' "$_ver"; cat "$CONFIG.tmp"; } > "$CONFIG.tmp.stamp"
    mv "$CONFIG.tmp.stamp" "$CONFIG.tmp"
  fi
  chmod 644 "$CONFIG.tmp" 2>/dev/null || true
  chown homeserver:homeserver "$CONFIG.tmp" 2>/dev/null || true
  mv "$CONFIG.tmp" "$CONFIG"
}

# Ensure data directory exists
mkdir -p "$DATA_DIR"

# Cloudflare Tunnel: read domain from dashboard-written file if present (overrides env)
# Publish gate: a domain only counts as a working permanent setup when a
# tunnel mode is configured alongside it, matching the dashboard's
# definition: domain AND (non-empty token OR config.yml present). The
# dashboard rejects domain-only saves nowadays, so the bare-domain branch
# only fires for stale or hand-edited state dirs; it falls through to the
# preview path or the localhost reset as usual.
if [ -f "$CF_DIR/domain" ] && [ -s "$CF_DIR/domain" ]; then
  if [ -s "$CF_DIR/token" ] || [ -f "$CF_DIR/config.yml" ]; then
    CLOUDFLARE_DOMAIN=$(tr -d '\n\r' < "$CF_DIR/domain")
    export CLOUDFLARE_DOMAIN
  else
    echo "WARNING: domain configured but no tunnel mode is set up (no token, no config.yml); not publishing" >&2
    CLOUDFLARE_DOMAIN=""
  fi
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
  # The version stamp lets migrate_config upgrade this file in future builds.
  {
    printf '# pubky-wrapper-template-version: %s\n' "$TEMPLATE_VERSION"
    envsubst < "$CONFIG_TEMPLATE"
  } > "$CONFIG.tmp"

  if [ -n "$DETECTED_PUBLIC_ICANN_HTTP_PORT" ]; then
    sed -i "/^icann_domain[[:space:]]*=/a public_icann_http_port = $DETECTED_PUBLIC_ICANN_HTTP_PORT" "$CONFIG.tmp"
  fi

  chmod 644 "$CONFIG.tmp" 2>/dev/null || true
  chown homeserver:homeserver "$CONFIG.tmp" 2>/dev/null || true
  mv "$CONFIG.tmp" "$CONFIG"
fi

# Bring pre-existing configs up to the current template version (no-op on a
# freshly generated file, which is stamped with TEMPLATE_VERSION already).
migrate_config

# Duplicate-key guard: a past sed bug class could leave more than one
# icann_domain line, and duplicate keys crash the homeserver's TOML parse.
# Keep the first and comment out the rest.
if [ -f "$CONFIG" ]; then
  DUP_COUNT=$(grep -c '^icann_domain[[:space:]]*=' "$CONFIG" || true)
  if [ "${DUP_COUNT:-0}" -gt 1 ]; then
    echo "WARNING: $DUP_COUNT icann_domain lines in config.toml; keeping the first and commenting out the rest" >&2
    awk '
      /^icann_domain[[:space:]]*=/ { if (seen++) { print "# " $0; next } }
      { print }
    ' "$CONFIG" > "$CONFIG.tmp"
    chmod 644 "$CONFIG.tmp" 2>/dev/null || true
    chown homeserver:homeserver "$CONFIG.tmp" 2>/dev/null || true
    mv "$CONFIG.tmp" "$CONFIG"
  fi
fi

# admin_password reconcile: the value is baked at first generation and the
# environment can drift afterwards (Umbrel regenerating APP_PASSWORD,
# reinstall patterns), which 401s the dashboard with no repair path. Rewrite
# the line from the current env on every boot. awk with a char loop (not
# sed) because the password may contain replacement metacharacters
# (&, \, |, quotes); the value is escaped per TOML basic-string rules.
if [ -f "$CONFIG" ] && [ -n "$ADMIN_PASSWORD" ] && grep -q '^admin_password[[:space:]]*=' "$CONFIG"; then
  ADMIN_PASSWORD="$ADMIN_PASSWORD" awk '
    BEGIN {
      v = ENVIRON["ADMIN_PASSWORD"]; out = ""
      n = length(v)
      for (i = 1; i <= n; i++) {
        c = substr(v, i, 1)
        if (c == "\\" || c == "\"") out = out "\\"
        out = out c
      }
    }
    /^admin_password[[:space:]]*=/ { print "admin_password = \"" out "\""; next }
    { print }
  ' "$CONFIG" > "$CONFIG.tmp"
  if cmp -s "$CONFIG.tmp" "$CONFIG"; then
    rm -f "$CONFIG.tmp"
  else
    echo "Reconciling admin_password with current environment"
    chmod 644 "$CONFIG.tmp" 2>/dev/null || true
    chown homeserver:homeserver "$CONFIG.tmp" 2>/dev/null || true
    mv "$CONFIG.tmp" "$CONFIG"
  fi
fi

# If config already exists and CLOUDFLARE_DOMAIN is set (e.g. from dashboard), update [pkdns]
if [ -f "$CONFIG" ] && [ -n "$CLOUDFLARE_DOMAIN" ]; then
  if grep -q '^icann_domain[[:space:]]*=' "$CONFIG"; then
    sed -i "s|^icann_domain[[:space:]]*=.*|icann_domain = \"$CLOUDFLARE_DOMAIN\"|" "$CONFIG"
  fi
  if ! grep -q '^public_icann_http_port[[:space:]]*=' "$CONFIG"; then
    sed -i "/^icann_domain[[:space:]]*=/a public_icann_http_port = 443" "$CONFIG"
  else
    sed -i 's|^public_icann_http_port[[:space:]]*=.*|public_icann_http_port = 443|' "$CONFIG"
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
  # Heal a mis-owned logfile too: cloudflared-preview re-opens quick.log by
  # name on every restart, and a file some other actor chowned away from
  # 65532 fails that open, so the URL never lands and the publish wait below
  # times out. 664: cloudflared writes as owner, the dashboard reads.
  if [ -f "$PREVIEW_DIR/quick.log" ]; then
    chown 65532:65532 "$PREVIEW_DIR/quick.log" 2>/dev/null || true
    chmod 664 "$PREVIEW_DIR/quick.log" 2>/dev/null || true
  fi
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
      sed -i "s|^icann_domain[[:space:]]*=.*|icann_domain = \"$PREVIEW_DOMAIN\"|" "$CONFIG"
      if ! grep -q '^public_icann_http_port[[:space:]]*=' "$CONFIG"; then
        sed -i "/^icann_domain[[:space:]]*=/a public_icann_http_port = 443" "$CONFIG"
      else
        sed -i 's|^public_icann_http_port[[:space:]]*=.*|public_icann_http_port = 443|' "$CONFIG"
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
      if grep -q '^icann_domain[[:space:]]*=[[:space:]]*".*\.trycloudflare\.com"' "$CONFIG"; then
        echo "WARNING: resetting stale trycloudflare icann_domain to localhost" >&2
        sed -i 's|^icann_domain[[:space:]]*=.*|icann_domain = "localhost"|' "$CONFIG"
        sed -i '/^public_icann_http_port[[:space:]]*=/d' "$CONFIG"
        chown homeserver:homeserver "$CONFIG" 2>/dev/null || true
      fi
    fi
  elif grep -q '^icann_domain[[:space:]]*=[[:space:]]*".*\.trycloudflare\.com"' "$CONFIG"; then
    # Preview was disabled: reset the stale random domain so the published
    # record stops pointing at a dead URL.
    echo "Preview mode disabled: resetting stale trycloudflare icann_domain to localhost"
    sed -i 's|^icann_domain[[:space:]]*=.*|icann_domain = "localhost"|' "$CONFIG"
    sed -i '/^public_icann_http_port[[:space:]]*=/d' "$CONFIG"
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

# Boot stamp: epoch of this wrapper run's successful completion, written
# last so its presence implies all config.toml patching above is done. The
# wrapper runs exactly once per app boot, immediately before the homeserver
# starts, so this timestamp is the best available proxy for "what the
# running homeserver last read". Contract: the dashboard (which mounts
# $DATA_DIR) compares cloudflare state-file mtimes against this stamp to
# derive a durable "restart pending" signal.
date +%s > "$DATA_DIR/.wrapper-boot-stamp.tmp"
chmod 644 "$DATA_DIR/.wrapper-boot-stamp.tmp" 2>/dev/null || true
chown homeserver:homeserver "$DATA_DIR/.wrapper-boot-stamp.tmp" 2>/dev/null || true
mv "$DATA_DIR/.wrapper-boot-stamp.tmp" "$DATA_DIR/.wrapper-boot-stamp"
