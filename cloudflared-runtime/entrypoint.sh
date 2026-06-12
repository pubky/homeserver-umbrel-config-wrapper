#!/bin/sh
# Entrypoint for cloudflared-runtime: ONE container that replaces the three
# compose cloudflared services (token / local / preview), two of which always
# crash-looped as a file-gating mechanism. Instead, this script picks the
# tunnel mode from the files present in the config dir and waits politely
# when none is configured.
#
# Precedence matches the dashboard's mode detection:
#   config.yml (connected account)  >  token  >  preview (testdrive.env)
# The dashboard's "connect" fingerprint also requires credentials.json, but
# config.yml is what tells cloudflared what to run (it references the
# credentials file internally), so config.yml alone selects the mode here,
# exactly like the old cloudflared-local service did.
#
# IMPORTANT: each mode is entered via `exec`, which replaces this shell with
# the cloudflared process. A mode CHANGE after that point therefore requires
# a container restart, exactly like the previous three-service setup where
# the user stops/starts the app to apply dashboard changes.

set -u

CONFIG_DIR="${CLOUDFLARED_CONFIG_DIR:-/etc/cloudflared-config}"
WAIT_SECS="${CLOUDFLARED_WAIT_SECS:-10}"

# --------------------------------------------------------- mode selection
# Pure file-fingerprint logic, free of any cloudflared invocation, so tests
# can source this file (CLOUDFLARED_RUNTIME_SOURCED=1) and exercise it.

# select_mode <dir>: prints one of: local | token | preview | wait
select_mode() {
  if [ -f "$1/config.yml" ]; then
    echo local
  elif [ -s "$1/token" ]; then
    # -s (non-empty): the dashboard truncates the file to clear the token,
    # and the old token-mode service errored on an empty file.
    echo token
  elif [ -f "$1/testdrive.env" ]; then
    echo preview
  else
    echo wait
  fi
}

# mode_args <mode> <dir>: prints the cloudflared argv, space separated (the
# fixed paths contain no spaces). Verbatim the args the three compose
# services ran:
#   local:   tunnel --no-autoupdate --config <dir>/config.yml run
#   token:   tunnel --no-autoupdate run        (token via TUNNEL_TOKEN_FILE)
#   preview: tunnel --no-autoupdate --logfile <dir>/preview/quick.log
#            (target URL via TUNNEL_URL, sourced from testdrive.env)
mode_args() {
  case "$1" in
    local)   echo "tunnel --no-autoupdate --config $2/config.yml run" ;;
    token)   echo "tunnel --no-autoupdate run" ;;
    preview) echo "tunnel --no-autoupdate --logfile $2/preview/quick.log" ;;
  esac
}

# mode_env <mode> <dir>: exports the env vars the mode needs, replicating
# the mechanisms the compose services used: TUNNEL_TOKEN_FILE for token mode
# (cloudflared reads the token from that file natively) and env_file
# testdrive.env -> TUNNEL_URL for preview mode. Returns non-zero when the
# mode's inputs are unusable (e.g. testdrive.env without a TUNNEL_URL) so
# the caller keeps waiting instead of exec'ing into a guaranteed crash.
mode_env() {
  case "$1" in
    token)
      TUNNEL_TOKEN_FILE="$2/token"
      export TUNNEL_TOKEN_FILE
      ;;
    preview)
      # The dashboard writes a single KEY=VALUE line, which is valid sh.
      # shellcheck disable=SC1090,SC1091
      . "$2/testdrive.env" || return 1
      [ -n "${TUNNEL_URL:-}" ] || return 1
      export TUNNEL_URL
      ;;
  esac
}

# ------------------------------------------------------------------- main

main() {
  last_logged=""
  while :; do
    mode="$(select_mode "$CONFIG_DIR")"
    if [ "$mode" = "wait" ]; then
      if [ "$last_logged" != "wait" ]; then
        echo "cloudflared-runtime: no tunnel configured in $CONFIG_DIR (no config.yml, token or testdrive.env); waiting"
        last_logged="wait"
      fi
      sleep "$WAIT_SECS"
      continue
    fi
    if ! mode_env "$mode" "$CONFIG_DIR"; then
      if [ "$last_logged" != "unusable-$mode" ]; then
        echo "cloudflared-runtime: mode $mode selected but its inputs are unusable (e.g. testdrive.env without TUNNEL_URL); waiting" >&2
        last_logged="unusable-$mode"
      fi
      sleep "$WAIT_SECS"
      continue
    fi
    args="$(mode_args "$mode" "$CONFIG_DIR")"
    echo "cloudflared-runtime: selected mode=$mode; exec cloudflared $args"
    # Intentional word splitting; see mode_args. exec replaces this shell,
    # so any later mode change needs a container restart (see header).
    # shellcheck disable=SC2086
    exec cloudflared $args
  done
}

if [ "${CLOUDFLARED_RUNTIME_SOURCED:-0}" != "1" ]; then
  main
fi
