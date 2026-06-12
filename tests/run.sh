#!/bin/sh
# Host-side harness for entrypoint.sh: runs the script against tmpdirs via
# the DATA_DIR/CLOUDFLARE_DIR/CONFIG_TEMPLATE overrides. No docker needed.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENTRY="$ROOT/entrypoint.sh"
TEMPLATE="$ROOT/config.toml.template"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
SUMMARY=""
SCEN_OK=1

# Stub envsubst if the host lacks it
if ! command -v envsubst >/dev/null 2>&1; then
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/envsubst" <<'EOF'
#!/bin/sh
# Minimal envsubst: substitutes ${VAR} occurrences from the environment.
awk '{
  line = $0
  while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    var = substr(line, RSTART + 2, RLENGTH - 3)
    line = substr(line, 1, RSTART - 1) ENVIRON[var] substr(line, RSTART + RLENGTH)
  }
  print line
}'
EOF
  chmod +x "$WORK/bin/envsubst"
  PATH="$WORK/bin:$PATH"
  export PATH
fi

# new_env NAME: creates $WORK/NAME/{data,cf}, sets DATA, CF, CONFIG
new_env() {
  ENVDIR="$WORK/$1"
  DATA="$ENVDIR/data"
  CF="$ENVDIR/cf"
  CONFIG="$DATA/config.toml"
  mkdir -p "$DATA" "$CF"
  SCEN_OK=1
}

# run_entry [extra VAR=value ...]: runs entrypoint.sh with the scenario dirs.
# ENTRY_SH overrides the shell that runs the entrypoint (e.g. "busybox sh");
# it is intentionally unquoted so a multi-word value splits.
run_entry() {
  env -i PATH="$PATH" \
    DATA_DIR="$DATA" CLOUDFLARE_DIR="$CF" CONFIG_TEMPLATE="$TEMPLATE" \
    PREVIEW_WAIT_SECS=2 \
    POSTGRES_PASSWORD=pgsecret ADMIN_PASSWORD=adminsecret \
    "$@" ${ENTRY_SH:-sh} "$ENTRY" > "$ENVDIR/stdout.log" 2> "$ENVDIR/stderr.log"
  RC=$?
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

assert_not() {
  _desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "    ASSERT FAILED: $_desc"
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

iso_at() { # iso_at <epoch>: ISO8601 UTC with Z
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -D %s -d "$1" +%Y-%m-%dT%H:%M:%SZ
}

NOW=$(date +%s)
OLD_TS=$(iso_at $((NOW - 3600)))
NEW_TS=$(iso_at "$NOW")

echo "Scenario 1: fresh generation produces valid config.toml"
new_env s1
run_entry
assert "exit 0" test "$RC" -eq 0
assert "config exists and is non-empty" test -s "$CONFIG"
assert "no leftover .tmp" test ! -e "$CONFIG.tmp"
assert "signup_mode present" grep -q '^signup_mode = "token_required"' "$CONFIG"
assert "database_url substituted" grep -q 'postgres://pubky:pgsecret@postgres' "$CONFIG"
assert "admin_password substituted" grep -q '^admin_password = "adminsecret"' "$CONFIG"
assert "icann_domain defaults to localhost" grep -q '^icann_domain = "localhost"' "$CONFIG"
assert "pkdns section present" grep -q '^\[pkdns\]' "$CONFIG"
assert_not "no active public_ip line (hostname -i gone)" grep -q '^public_ip = ' "$CONFIG"
assert "public_ip commented with hint" grep -q '^# public_ip omitted' "$CONFIG"
# Explicit PUBLIC_IP env is honored
new_env s1b
run_entry PUBLIC_IP=203.0.113.7
assert "explicit PUBLIC_IP is written" grep -q '^public_ip = "203.0.113.7"' "$CONFIG"
finish "fresh generation"

echo "Scenario 2: zero-byte config.toml regenerates"
new_env s2
touch "$CONFIG"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "regeneration warned" grep -q "is empty" "$ENVDIR/stderr.log"
assert "config regenerated non-empty" test -s "$CONFIG"
assert "icann_domain present" grep -q '^icann_domain = "localhost"' "$CONFIG"
finish "zero-byte config regenerates"

echo "Scenario 3: interrupted render leaves no truncated final file"
new_env s3
printf '[general]\nsignup' > "$CONFIG.tmp"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "final config complete" grep -q '^icann_domain = "localhost"' "$CONFIG"
assert "admin section rendered" grep -q '^admin_password = "adminsecret"' "$CONFIG"
assert "no leftover .tmp" test ! -e "$CONFIG.tmp"
finish "interrupted render heals"

echo "Scenario 4: domain + token publishes icann_domain + port 443 (+ public_ip heal)"
new_env s4
cat > "$CONFIG" <<'EOF'
[pkdns]
public_ip = "172.18.0.5"
icann_domain = "localhost"
user_keys_republisher_interval = 14400
EOF
printf 'example.com\n' > "$CF/domain"
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "icann_domain updated" grep -q '^icann_domain = "example.com"' "$CONFIG"
assert "port 443 added" grep -q '^public_icann_http_port = 443' "$CONFIG"
assert_not "docker-internal public_ip no longer active" grep -q '^public_ip = ' "$CONFIG"
assert "old public_ip commented" grep -q '^# public_ip = "172.18.0.5"' "$CONFIG"
finish "domain file publish + heal"

echo "Scenario 5: bad-charset domain is ignored with warning"
new_env s5
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "localhost"
EOF
printf 'bad domain|x\n' > "$CF/domain"
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "warning emitted" grep -q 'characters outside' "$ENVDIR/stderr.log"
assert "icann_domain untouched" grep -q '^icann_domain = "localhost"' "$CONFIG"
assert_not "no port 443 injected" grep -q '^public_icann_http_port = ' "$CONFIG"
finish "bad-charset domain ignored"

echo "Scenario 6: preview publishes the NEW-timestamp URL and writes published"
new_env s6
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "localhost"
EOF
touch "$CF/testdrive.env"
mkdir -p "$CF/preview"
cat > "$CF/preview/quick.log" <<EOF
{"level":"info","time":"$OLD_TS","message":"+ https://old-dead.trycloudflare.com +"}
{"level":"error","time":"$NEW_TS","message":"Requesting https://api.trycloudflare.com/tunnel"}
{"level":"info","time":"$NEW_TS","message":"+ https://fresh-json.trycloudflare.com +"}
$NEW_TS INF |  https://fresh-text.trycloudflare.com  |
EOF
run_entry
assert "exit 0" test "$RC" -eq 0
assert "newest fresh URL published" grep -q '^icann_domain = "fresh-text.trycloudflare.com"' "$CONFIG"
assert "port 443 added" grep -q '^public_icann_http_port = 443' "$CONFIG"
assert "handshake file written" test -f "$CF/preview/published"
assert "handshake contains the URL" grep -q '^https://fresh-text.trycloudflare.com$' "$CF/preview/published"
assert_not "old URL not published" grep -q 'old-dead' "$CONFIG"
finish "preview fresh URL published"

echo "Scenario 7: preview timeout resets stale trycloudflare domain"
new_env s7
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "previous-boot.trycloudflare.com"
public_icann_http_port = 443
EOF
touch "$CF/testdrive.env"
mkdir -p "$CF/preview"
cat > "$CF/preview/quick.log" <<EOF
{"level":"info","time":"$OLD_TS","message":"+ https://previous-boot.trycloudflare.com +"}
{"level":"info","message":"+ https://no-timestamp.trycloudflare.com +"}
EOF
printf 'https://previous-boot.trycloudflare.com\n' > "$CF/preview/published"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "timeout warned with correct wait" grep -q 'within 2s' "$ENVDIR/stderr.log"
assert "stale domain reset to localhost" grep -q '^icann_domain = "localhost"' "$CONFIG"
assert_not "port line removed" grep -q '^public_icann_http_port = ' "$CONFIG"
assert "published handshake removed" test ! -e "$CF/preview/published"
finish "preview timeout resets"

echo "Scenario 8: domain + testdrive.env removes the preview marker"
new_env s8
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "old-preview.trycloudflare.com"
public_icann_http_port = 443
EOF
printf 'example.org\n' > "$CF/domain"
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
touch "$CF/testdrive.env"
mkdir -p "$CF/preview"
printf 'noise\n' > "$CF/preview/quick.log"
printf 'https://old-preview.trycloudflare.com\n' > "$CF/preview/published"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "testdrive.env removed" test ! -e "$CF/testdrive.env"
assert "removal logged" grep -q 'removing leftover preview marker' "$ENVDIR/stdout.log"
assert "domain published" grep -q '^icann_domain = "example.org"' "$CONFIG"
assert "quick.log removed (preview off)" test ! -e "$CF/preview/quick.log"
assert "published handshake removed (preview off)" test ! -e "$CF/preview/published"
finish "domain supersedes preview"

echo "Scenario 9: admin_password drift is reconciled on boot"
new_env s9
run_entry
assert "initial password baked" grep -q '^admin_password = "adminsecret"' "$CONFIG"
# Drifted env, including sed/TOML metacharacters: & | \ " '
TRICKY='a&b|c\d"e'\''f'
EXPECTED='admin_password = "a&b|c\\d\"e'\''f"'
run_entry ADMIN_PASSWORD="$TRICKY"
assert "exit 0" test "$RC" -eq 0
assert "reconcile logged" grep -q 'Reconciling admin_password' "$ENVDIR/stdout.log"
assert "tricky password written TOML-escaped" grep -qF "$EXPECTED" "$CONFIG"
assert "no leftover .tmp" test ! -e "$CONFIG.tmp"
# Same env again: no rewrite
run_entry ADMIN_PASSWORD="$TRICKY"
assert_not "no reconcile when already current" grep -q 'Reconciling admin_password' "$ENVDIR/stdout.log"
assert "password still present" grep -qF "$EXPECTED" "$CONFIG"
finish "admin_password reconcile"

echo "Scenario 10: template version stamp written at generation"
new_env s10
run_entry
assert "exit 0" test "$RC" -eq 0
assert "stamp present" grep -q '^# pubky-wrapper-template-version: 1$' "$CONFIG"
assert_not "no migration ran on fresh config" grep -q 'Migrating config.toml' "$ENVDIR/stdout.log"
finish "stamp at generation"

echo "Scenario 11: stamp-absent old config migrates to v1 exactly once"
new_env s11
cat > "$CONFIG" <<'EOF'
[admin]
admin_password = "adminsecret"

[pkdns]
public_ip = "172.19.0.3"
icann_domain = "localhost"
EOF
run_entry
assert "exit 0" test "$RC" -eq 0
assert "migration logged" grep -q 'Migrating config.toml from template version 0 to 1' "$ENVDIR/stdout.log"
assert "stamp written" grep -q '^# pubky-wrapper-template-version: 1$' "$CONFIG"
assert "docker-internal public_ip commented" grep -q '^# public_ip = "172.19.0.3"' "$CONFIG"
assert_not "no active public_ip line" grep -q '^public_ip' "$CONFIG"
assert "no leftover .tmp" test ! -e "$CONFIG.tmp"
cp "$CONFIG" "$ENVDIR/after-first.toml"
# Second boot: idempotent, nothing changes
run_entry
assert "exit 0 on second boot" test "$RC" -eq 0
assert_not "migration not re-run" grep -q 'Migrating config.toml' "$ENVDIR/stdout.log"
assert "config byte-identical on second boot" cmp -s "$ENVDIR/after-first.toml" "$CONFIG"
assert "exactly one stamp line" test "$(grep -c '^# pubky-wrapper-template-version' "$CONFIG")" -eq 1
finish "stamp-absent migration"

echo "Scenario 12: whitespace-variant icann_domain still patched by domain flow"
new_env s12
cat > "$CONFIG" <<'EOF'
# pubky-wrapper-template-version: 1
[pkdns]
icann_domain   =   "localhost"
EOF
printf 'space.example.com\n' > "$CF/domain"
printf 'eyJhIjoiYiJ9\n' > "$CF/token"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "icann_domain patched despite extra whitespace" grep -q '^icann_domain = "space.example.com"' "$CONFIG"
assert "port 443 added" grep -q '^public_icann_http_port = 443' "$CONFIG"
finish "whitespace-tolerant patching"

echo "Scenario 13: duplicate icann_domain lines deduped, first preserved"
new_env s13
cat > "$CONFIG" <<'EOF'
# pubky-wrapper-template-version: 1
[pkdns]
icann_domain = "first.example.com"
icann_domain = "second.example.com"
EOF
run_entry
assert "exit 0" test "$RC" -eq 0
assert "warning emitted" grep -q 'icann_domain lines' "$ENVDIR/stderr.log"
assert "first kept active" grep -q '^icann_domain = "first.example.com"' "$CONFIG"
assert "second commented" grep -q '^# icann_domain = "second.example.com"' "$CONFIG"
assert "exactly one active icann_domain" test "$(grep -c '^icann_domain' "$CONFIG")" -eq 1
finish "duplicate icann_domain dedupe"

echo "Scenario 14: successful run writes a fresh boot stamp"
new_env s14
T0=$(date +%s)
run_entry
T1=$(date +%s)
assert "exit 0" test "$RC" -eq 0
assert "boot stamp exists non-empty" test -s "$DATA/.wrapper-boot-stamp"
STAMP=$(tr -d '\n' < "$DATA/.wrapper-boot-stamp" 2>/dev/null || echo "")
case "$STAMP" in
  ''|*[!0-9]*) STAMP=0 ;;
esac
assert "stamp not older than run start" test "$STAMP" -ge "$T0"
assert "stamp not in the future" test "$STAMP" -le "$T1"
assert "no leftover stamp .tmp" test ! -e "$DATA/.wrapper-boot-stamp.tmp"
finish "boot stamp on success"

echo "Scenario 15: domain + config.yml (no token) publishes"
new_env s15
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "localhost"
EOF
printf 'byo.example.com\n' > "$CF/domain"
printf 'tunnel: abc\n' > "$CF/config.yml"
run_entry
assert "exit 0" test "$RC" -eq 0
assert "icann_domain published" grep -q '^icann_domain = "byo.example.com"' "$CONFIG"
assert "port 443 added" grep -q '^public_icann_http_port = 443' "$CONFIG"
finish "domain + config.yml publishes"

echo "Scenario 16: domain with no tunnel mode does not publish, stamp still written"
new_env s16
cat > "$CONFIG" <<'EOF'
[pkdns]
icann_domain = "localhost"
EOF
printf 'orphan.example.com\n' > "$CF/domain"
touch "$CF/token" # zero-byte token does not count as a tunnel mode
run_entry
assert "exit 0" test "$RC" -eq 0
assert "warning emitted" grep -q 'domain configured but no tunnel mode is set up' "$ENVDIR/stderr.log"
assert "warning says not publishing" grep -q 'not publishing' "$ENVDIR/stderr.log"
assert "icann_domain stays localhost" grep -q '^icann_domain = "localhost"' "$CONFIG"
assert_not "domain not published" grep -q 'orphan.example.com' "$CONFIG"
assert_not "no port 443 injected" grep -q '^public_icann_http_port = ' "$CONFIG"
assert "boot stamp written on not-publishing path" test -s "$DATA/.wrapper-boot-stamp"
finish "ungated domain not published"

echo ""
echo "==== Summary ====$SUMMARY"
echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
