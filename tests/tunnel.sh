#!/bin/sh
# Host-side harness for tunnel.sh, with a stub cloudflared that records how it
# was called. No docker needed. Usage: tests/tunnel.sh   (TUNNEL_SH="busybox sh" to vary the shell)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${TUNNEL_SH:-sh}
FAILS=0

mkdir -p "$WORK/bin"
cat > "$WORK/bin/cloudflared" <<'STUB'
#!/bin/sh
echo "args=$* url=${TUNNEL_URL:-}" > "$CALLED"
STUB
chmod +x "$WORK/bin/cloudflared"

new_dir() { DIR="$WORK/$1"; mkdir -p "$DIR/preview"; CALLED="$DIR/called"; export CALLED; }
run() { PATH="$WORK/bin:$PATH" CLOUDFLARED_CONFIG_DIR="$DIR" TUNNEL_WAIT_SECS=1 $SH "$ROOT/tunnel.sh" > "$DIR/out" 2>&1; }
check() { # check "description" expected-substring file
  if grep -qF -- "$2" "$3" 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1 (wanted: $2)"; FAILS=$((FAILS + 1)); fi
}

new_dir persistent
: > "$DIR/config.yml"
run
check "config.yml runs the persistent tunnel" "args=tunnel --no-autoupdate --config $DIR/config.yml run url=" "$CALLED"

new_dir preview
echo "TUNNEL_URL=http://homeserver:6286" > "$DIR/testdrive.env"
run
check "testdrive.env runs a quick tunnel" "args=tunnel --no-autoupdate --logfile $DIR/preview/quick.log url=http://homeserver:6286" "$CALLED"

new_dir both
: > "$DIR/config.yml"
echo "TUNNEL_URL=http://homeserver:6286" > "$DIR/testdrive.env"
run
check "a persistent tunnel wins over preview" "--config $DIR/config.yml run" "$CALLED"

new_dir empty-marker
: > "$DIR/testdrive.env"
(sleep 2; : > "$DIR/config.yml") &
run
check "a marker without a URL does not start a quick tunnel" "--config $DIR/config.yml run" "$CALLED"

new_dir late
(sleep 2; : > "$DIR/config.yml") &
run
check "idles, then starts when config.yml appears" "--config $DIR/config.yml run" "$CALLED"
check "says it is waiting" "No tunnel is set up yet" "$DIR/out"

new_dir stop
PATH="$WORK/bin:$PATH" CLOUDFLARED_CONFIG_DIR="$DIR" TUNNEL_WAIT_SECS=30 $SH "$ROOT/tunnel.sh" > "$DIR/out" 2>&1 &
PID=$!
sleep 1
kill -TERM "$PID"
( sleep 5; kill -KILL "$PID" 2>/dev/null ) &
wait "$PID"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -f "$CALLED" ]; then echo "ok   SIGTERM while idle exits cleanly"; else echo "FAIL SIGTERM while idle (rc=$RC)"; FAILS=$((FAILS + 1)); fi

[ "$FAILS" -eq 0 ] && echo "all tunnel.sh scenarios passed" || { echo "$FAILS scenario(s) failed"; exit 1; }
