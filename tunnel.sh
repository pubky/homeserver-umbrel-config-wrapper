#!/bin/sh
# Runs the app's Cloudflare tunnel, and idles while none is set up.
#
# The official cloudflared image has no shell, so the only way to gate it on
# the dashboard's files was to let the container crash-loop until they
# appeared. This script selects the tunnel from those same files instead:
#
#   config.yml      the persistent tunnel, started as soon as the file exists
#   testdrive.env   Preview mode, an account-less quick tunnel, chosen only at
#                   container start: its address is published by the app
#                   restart that follows enabling it

set -u

DIR="${CLOUDFLARED_CONFIG_DIR:-/etc/cloudflared-config}"
WAIT_SECS="${TUNNEL_WAIT_SECS:-10}"

# sh as PID 1 ignores SIGTERM by default, which would stall every app stop.
trap 'exit 0' TERM INT

if [ ! -f "$DIR/config.yml" ] && [ -f "$DIR/testdrive.env" ]; then
  TUNNEL_URL=$(sed -n 's/^TUNNEL_URL=//p' "$DIR/testdrive.env" | head -n 1)
  if [ -n "$TUNNEL_URL" ]; then
    export TUNNEL_URL
    echo "Preview mode: starting a quick tunnel to $TUNNEL_URL"
    exec cloudflared tunnel --no-autoupdate --logfile "$DIR/preview/quick.log"
  fi
fi

if [ ! -f "$DIR/config.yml" ]; then
  echo "No tunnel is set up yet. Waiting for one to be configured in the dashboard."
  while [ ! -f "$DIR/config.yml" ]; do
    sleep "$WAIT_SECS" &
    wait $!
  done
fi

echo "Starting the tunnel from $DIR/config.yml"
exec cloudflared tunnel --no-autoupdate --config "$DIR/config.yml" run
