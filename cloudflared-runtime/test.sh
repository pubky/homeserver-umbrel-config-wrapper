#!/bin/sh
# Host-side tests for the cloudflared-runtime mode selection. Sources
# entrypoint.sh (CLOUDFLARED_RUNTIME_SOURCED=1) to test the fingerprint
# functions directly, then runs the full entrypoint against a stub
# cloudflared on PATH to assert the exec'd mode + args. No docker needed.
set -u

ROOT=$(cd "$(dirname "$0")" && pwd)
ENTRY="$ROOT/entrypoint.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
SUMMARY=""
SCEN_OK=1

new_env() {
  CF="$WORK/$1"
  mkdir -p "$CF/preview"
  SCEN_OK=1
}

assert() { # assert "description" command...
  _desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    :
  else
    echo "    ASSERT FAILED: $_desc"
    SCEN_OK=0
  fi
}

assert_eq() { # assert_eq "description" expected actual
  if [ "$2" = "$3" ]; then
    :
  else
    echo "    ASSERT FAILED: $1 (expected '$2', got '$3')"
    SCEN_OK=0
  fi
}

finish() { # finish "scenario name"
  if [ "$SCEN_OK" -eq 1 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    SUMMARY="$SUMMARY
PASS  $1"
    echo "  PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SUMMARY="$SUMMARY
FAIL  $1"
    echo "  FAIL"
  fi
}

# Stub cloudflared: records its argv and relevant env, then exits 0. Because
# the entrypoint exec's it, the entrypoint process ends right there, which is
# exactly the behavior under test.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cloudflared" <<'EOF'
#!/bin/sh
echo "ARGS:$*"
echo "TUNNEL_TOKEN_FILE:${TUNNEL_TOKEN_FILE:-}"
echo "TUNNEL_URL:${TUNNEL_URL:-}"
EOF
chmod +x "$WORK/bin/cloudflared"

# run_entry: runs the real entrypoint with the stub first on PATH.
run_entry() {
  env -i PATH="$WORK/bin:$PATH" \
    CLOUDFLARED_CONFIG_DIR="$CF" CLOUDFLARED_WAIT_SECS=1 \
    sh "$ENTRY" > "$CF/stdout.log" 2> "$CF/stderr.log"
  RC=$?
}

# Load the fingerprint functions without running main.
CLOUDFLARED_RUNTIME_SOURCED=1
. "$ENTRY"

echo "Scenario 1: empty config dir selects wait"
new_env s1
assert_eq "mode is wait" "wait" "$(select_mode "$CF")"
finish "empty dir -> wait"

echo "Scenario 2: non-empty token selects token with the compose args"
new_env s2
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
assert_eq "mode is token" "token" "$(select_mode "$CF")"
assert_eq "token args" "tunnel --no-autoupdate run" "$(mode_args token "$CF")"
( mode_env token "$CF" \
    && [ "$TUNNEL_TOKEN_FILE" = "$CF/token" ] ) || SCEN_OK=0
finish "token fingerprint"

echo "Scenario 3: empty token file does NOT select token (waits)"
new_env s3
: > "$CF/token"
assert_eq "mode is wait" "wait" "$(select_mode "$CF")"
finish "empty token -> wait"

echo "Scenario 4: config.yml selects local mode"
new_env s4
printf 'tunnel: abc\n' > "$CF/config.yml"
assert_eq "mode is local" "local" "$(select_mode "$CF")"
assert_eq "local args" \
  "tunnel --no-autoupdate --config $CF/config.yml run" \
  "$(mode_args local "$CF")"
finish "config.yml fingerprint"

echo "Scenario 5: testdrive.env selects preview, TUNNEL_URL exported"
new_env s5
printf 'TUNNEL_URL=http://homeserver:6286\n' > "$CF/testdrive.env"
assert_eq "mode is preview" "preview" "$(select_mode "$CF")"
assert_eq "preview args" \
  "tunnel --no-autoupdate --logfile $CF/preview/quick.log" \
  "$(mode_args preview "$CF")"
( mode_env preview "$CF" \
    && [ "$TUNNEL_URL" = "http://homeserver:6286" ] ) || SCEN_OK=0
finish "preview fingerprint"

echo "Scenario 6: precedence is config.yml > token > preview"
new_env s6
printf 'TUNNEL_URL=http://homeserver:6286\n' > "$CF/testdrive.env"
assert_eq "preview alone" "preview" "$(select_mode "$CF")"
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
assert_eq "token beats preview" "token" "$(select_mode "$CF")"
printf 'tunnel: abc\n' > "$CF/config.yml"
assert_eq "config.yml beats both" "local" "$(select_mode "$CF")"
finish "mode precedence"

echo "Scenario 7: testdrive.env without TUNNEL_URL is unusable"
new_env s7
: > "$CF/testdrive.env"
assert_eq "mode is preview" "preview" "$(select_mode "$CF")"
( unset TUNNEL_URL; ! mode_env preview "$CF" ) || SCEN_OK=0
finish "empty testdrive.env unusable"

echo "Scenario 8: full entrypoint execs cloudflared in token mode"
new_env s8
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "mode line logged" grep -q '^cloudflared-runtime: selected mode=token; exec cloudflared tunnel --no-autoupdate run$' "$CF/stdout.log"
assert "stub got the args" grep -q '^ARGS:tunnel --no-autoupdate run$' "$CF/stdout.log"
assert "TUNNEL_TOKEN_FILE passed through" grep -q "^TUNNEL_TOKEN_FILE:$CF/token$" "$CF/stdout.log"
finish "entrypoint token exec"

echo "Scenario 9: full entrypoint execs cloudflared in preview mode"
new_env s9
printf 'TUNNEL_URL=http://homeserver:6286\n' > "$CF/testdrive.env"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "mode line logged" grep -q "^cloudflared-runtime: selected mode=preview; exec cloudflared tunnel --no-autoupdate --logfile $CF/preview/quick.log$" "$CF/stdout.log"
assert "stub got the args" grep -q "^ARGS:tunnel --no-autoupdate --logfile $CF/preview/quick.log$" "$CF/stdout.log"
assert "TUNNEL_URL passed through" grep -q '^TUNNEL_URL:http://homeserver:6286$' "$CF/stdout.log"
finish "entrypoint preview exec"

echo "Scenario 10: full entrypoint execs cloudflared in local mode"
new_env s10
printf 'tunnel: abc\n' > "$CF/config.yml"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "mode line logged" grep -q "^cloudflared-runtime: selected mode=local; exec cloudflared tunnel --no-autoupdate --config $CF/config.yml run$" "$CF/stdout.log"
assert "stub got the args" grep -q "^ARGS:tunnel --no-autoupdate --config $CF/config.yml run$" "$CF/stdout.log"
finish "entrypoint local exec"

echo "Scenario 11: no mode -> logs waiting once and stays up (no crash-loop)"
new_env s11
env -i PATH="$WORK/bin:$PATH" \
  CLOUDFLARED_CONFIG_DIR="$CF" CLOUDFLARED_WAIT_SECS=1 \
  sh "$ENTRY" > "$CF/stdout.log" 2> "$CF/stderr.log" &
EP_PID=$!
sleep 3
assert "still running after 3s" kill -0 "$EP_PID"
assert "waiting message logged" grep -q 'no tunnel configured' "$CF/stdout.log"
assert_eq "waiting message logged exactly once" "1" "$(grep -c 'no tunnel configured' "$CF/stdout.log")"
# A mode appearing while it waits is picked up on the next loop iteration.
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
sleep 2
assert "picked up token mode" grep -q 'selected mode=token' "$CF/stdout.log"
wait "$EP_PID" 2>/dev/null
finish "wait loop"

echo ""
echo "==== Summary ====$SUMMARY"
echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
