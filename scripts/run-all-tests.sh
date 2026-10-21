#!/usr/bin/env bash
#
# run-all-tests.sh — the whole SequelBridge test suite, A to Z, from scratch.
#
# The hermetic unit tests (DuckDB, SQL builders, parsers, UI logic) always run.
# The gated real-DB suites (MySQL/MariaDB, PostgreSQL, ClickHouse, cross-engine
# JOIN reduction, the ClickHouse bridge, production schema shapes, connections
# through SSH tunnels and Unix sockets) run against throwaway Docker containers this
# script can provision and seed for you, plus a local Unix-socket relay it starts.
# Every MySQL suite runs twice: against MariaDB 10.0, then against MySQL 8.4.
#
# Usage:
#   scripts/run-all-tests.sh                 # reuse running containers, run everything
#   scripts/run-all-tests.sh --provision     # (re)create + seed containers, then run  [canonical]
#   scripts/run-all-tests.sh --seed          # (re)seed running containers, then run
#   scripts/run-all-tests.sh --hermetic      # only the no-DB unit tests (fast, no Docker)
#   scripts/run-all-tests.sh --down          # tear the containers down and exit
#   scripts/run-all-tests.sh --bench         # also run the Release cross-engine benchmark
#
# Options:
#   --release         build/test in Release (DuckDB is 20-100x faster; honest numbers)
#   --only "A/B C/D"  pass -only-testing filters (space-separated) straight to xcodebuild
#   --mysql-port N    point the MySQL-family suites at port N (3311 MySQL 8.4, 3312 MariaDB
#                     11.4, 3313 MySQL 8.0) instead of MariaDB 10.0, for a targeted run
#   --no-build        skip the plain build step, go straight to tests
#   --arch x86_64     build and test for Intel; on Apple Silicon it runs under Rosetta
#
# Every gated suite is pointed at these containers via TEST_RUNNER_SB_* env vars
# (Xcode strips the TEST_RUNNER_ prefix before the test process sees them), so a
# feature's tests find their data no matter which suite's defaults they carry.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
FIX="$ROOT/scripts/fixtures"

# ---- container topology (one place; the env block below mirrors it) ---------
MARIA=sb-mariadb10      ; MARIA_PORT=3309   ; MARIA_IMG=mariadb:10.0
MARIA2=sb-mariadb10-b   ; MARIA2_PORT=3310                          # MultiServer PORT2
MYSQL8=sb-mysql8        ; MYSQL8_PORT=3311  ; MYSQL8_IMG=mysql:8.4  # the MySQL 8.4 pass
# What most servers run today (MariaDB 10.0 is from 2014): MariaDB 11.4 LTS reports a
# column's default quoted and CURRENT_TIMESTAMP as current_timestamp(); MySQL 8.0.
MARIA11=sb-mariadb11    ; MARIA11_PORT=3312 ; MARIA11_IMG=mariadb:11.4
MYSQL80=sb-mysql80      ; MYSQL80_PORT=3313 ; MYSQL80_IMG=mysql:8.0
MY_ROOT_PW=sbverify123
PG=sb-postgres          ; PG_PORT=5433      ; PG_IMG=postgres:16
PG_USER=sbuser          ; PG_PW=sbpass123   ; PG_DB=sbtest
PGSSL=sb-postgres-ssl   ; PGSSL_PORT=5434   # the same, with TLS on
CH=sb-clickhouse        ; CH_HTTP=8123      ; CH_NATIVE=9000        ; CH_IMG=clickhouse/clickhouse-server:latest
CH_USER=sbuser          ; CH_PW=sbpass123
# SSH server for the tunnel tests: today's defaults on SSH_PORT, an old server that
# offers only ssh-rsa on SSH_LEGACY_PORT (scripts/fixtures/ssh/sshd-setup.sh).
SSHD=sb-sshd            ; SSH_PORT=2224     ; SSH_LEGACY_PORT=2225  ; SSHD_IMG=alpine:3.20
SSH_DIR="$ROOT/.build/ssh"                      # the test key and stable host keys (not in git)
SOCK_DIR=/tmp/sb-sock                           # Unix sockets relayed to MariaDB and PostgreSQL

CONFIG=Debug
MODE=run                 # run | provision | seed | hermetic | down
RUN_BENCH=0
NO_BUILD=0
ONLY=""
MYSQL_PORT_OVERRIDE=""
DESTINATION='platform=macOS'

while [ $# -gt 0 ]; do
  case "$1" in
    --provision) MODE=provision ;;
    --seed)      MODE=seed ;;
    --hermetic)  MODE=hermetic ;;
    --down)      MODE=down ;;
    --bench)     RUN_BENCH=1 ;;
    --release)   CONFIG=Release ;;
    --no-build)  NO_BUILD=1 ;;
    --only)      ONLY="$2"; shift ;;
    --mysql-port) MYSQL_PORT_OVERRIDE="$2"; shift ;;
    --arch)      DESTINATION="platform=macOS,arch=$2"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }

need_docker() {
  command -v docker >/dev/null || { echo "docker is required for the real-DB suites (use --hermetic to skip them)"; exit 1; }
}

# ---- provisioning ----------------------------------------------------------
wait_for() { # name cmd...
  local name="$1"; shift
  for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && { ok "$name ready"; return 0; }; sleep 1; done
  echo "timed out waiting for $name" >&2; exit 1
}

provision() {
  need_docker
  say "Provisioning throwaway containers (fresh)"
  docker rm -f "$MARIA" "$MARIA2" "$MYSQL8" "$MARIA11" "$MYSQL80" "$PG" "$PGSSL" "$CH" >/dev/null 2>&1 || true

  docker run -d --name "$MARIA"  -e MYSQL_ROOT_PASSWORD="$MY_ROOT_PW" -p "$MARIA_PORT:3306"  "$MARIA_IMG"  >/dev/null
  docker run -d --name "$MARIA2" -e MYSQL_ROOT_PASSWORD="$MY_ROOT_PW" -p "$MARIA2_PORT:3306" "$MARIA_IMG"  >/dev/null
  docker run -d --name "$PG" -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB="$PG_DB" -p "$PG_PORT:5432" "$PG_IMG" >/dev/null
  docker run -d --name "$CH" -e CLICKHOUSE_USER="$CH_USER" -e CLICKHOUSE_PASSWORD="$CH_PW" \
    -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 -p "$CH_HTTP:8123" -p "$CH_NATIVE:9000" "$CH_IMG" >/dev/null

  # Authenticated TCP query, not `ping`: mysqladmin ping reports alive during the init
  # window, and the image's temporary init server runs with --skip-networking. Forcing
  # TCP (--protocol=TCP) only succeeds once the real, networked server with the root
  # password is up, so the seed never races a half-initialized server.
  wait_for "$MARIA"  docker exec "$MARIA"  mysql --protocol=TCP -h127.0.0.1 -uroot -p"$MY_ROOT_PW" -e "SELECT 1"
  wait_for "$MARIA2" docker exec "$MARIA2" mysql --protocol=TCP -h127.0.0.1 -uroot -p"$MY_ROOT_PW" -e "SELECT 1"
  wait_for "$PG"     docker exec "$PG"     psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1"
  wait_for "$CH"     docker exec "$CH"     clickhouse-client -u "$CH_USER" --password "$CH_PW" -q "SELECT 1"
  start_sshd
  seed
  start_mysql8
  start_mariadb11
  start_mysql80
  start_pgssl
}

# MySQL 8.4: caching_sha2_password at login, strict SQL mode, utf8mb4_0900 collations.
# The deprecated mysql_native_password plugin is switched on for one test account, so the
# client's switch between login methods is covered too. Seeded like MariaDB.
start_mysql8() {
  docker rm -f "$MYSQL8" >/dev/null 2>&1 || true
  docker run -d --name "$MYSQL8" -e MYSQL_ROOT_PASSWORD="$MY_ROOT_PW" -p "$MYSQL8_PORT:3306" \
    "$MYSQL8_IMG" --mysql-native-password=ON >/dev/null
  wait_for "$MYSQL8" docker exec "$MYSQL8" mysql --protocol=TCP -h127.0.0.1 -uroot -p"$MY_ROOT_PW" -e "SELECT 1"
  docker exec -i "$MYSQL8" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"
  docker exec -i "$MYSQL8" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql8.sql"; ok "mysql 8.4 $MYSQL8_PORT (sbtest/sbwrite/sbreal, sbnative)"
}

# MariaDB 11.4: its image ships the mariadb client only (no `mysql`). Seeded like 10.0.
start_mariadb11() {
  docker rm -f "$MARIA11" >/dev/null 2>&1 || true
  docker run -d --name "$MARIA11" -e MARIADB_ROOT_PASSWORD="$MY_ROOT_PW" -p "$MARIA11_PORT:3306" "$MARIA11_IMG" >/dev/null
  wait_for "$MARIA11" docker exec "$MARIA11" mariadb --protocol=TCP -h127.0.0.1 -uroot -p"$MY_ROOT_PW" -e "SELECT 1"
  docker exec -i "$MARIA11" mariadb -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"; ok "mariadb 11.4 $MARIA11_PORT (sbtest/sbwrite/sbreal)"
}

# PostgreSQL with TLS on, using the image's own snakeoil certificate: Use SSL and the
# app's own PostgreSQL client switching to TLS.
start_pgssl() {
  docker rm -f "$PGSSL" >/dev/null 2>&1 || true
  docker run -d --name "$PGSSL" -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB="$PG_DB" \
    -p "$PGSSL_PORT:5432" "$PG_IMG" -c ssl=on \
    -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key >/dev/null
  wait_for "$PGSSL" docker exec "$PGSSL" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1"
  ok "postgres with SSL $PGSSL_PORT"
}

# MySQL 8.0: caching_sha2_password at login, mysql_native_password still built in.
start_mysql80() {
  docker rm -f "$MYSQL80" >/dev/null 2>&1 || true
  docker run -d --name "$MYSQL80" -e MYSQL_ROOT_PASSWORD="$MY_ROOT_PW" -p "$MYSQL80_PORT:3306" "$MYSQL80_IMG" >/dev/null
  wait_for "$MYSQL80" docker exec "$MYSQL80" mysql --protocol=TCP -h127.0.0.1 -uroot -p"$MY_ROOT_PW" -e "SELECT 1"
  docker exec -i "$MYSQL80" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"
  docker exec -i "$MYSQL80" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql8.sql"; ok "mysql 8.0 $MYSQL80_PORT (sbtest/sbwrite/sbreal, sbnative)"
}

# The SSH server. Its host keys are generated once and kept, so the known_hosts entry
# the app's tunnel adds (StrictHostKeyChecking=accept-new) stays valid across runs.
start_sshd() {
  mkdir -p "$SSH_DIR/hostkeys"
  [ -f "$SSH_DIR/sb_test_key" ] || ssh-keygen -q -t rsa -b 3072 -N "" -C sequelbridge-test -f "$SSH_DIR/sb_test_key"
  [ -f "$SSH_DIR/sb_phrase_key" ] || ssh-keygen -q -t ed25519 -N "sbphrase" -C sequelbridge-phrase -f "$SSH_DIR/sb_phrase_key"
  local t; for t in rsa ed25519; do
    [ -f "$SSH_DIR/hostkeys/ssh_host_${t}_key" ] || ssh-keygen -q -t "$t" -N "" -C sb-sshd -f "$SSH_DIR/hostkeys/ssh_host_${t}_key"
  done
  docker rm -f "$SSHD" >/dev/null 2>&1 || true
  docker run -d --name "$SSHD" -p "$SSH_PORT:2222" -p "$SSH_LEGACY_PORT:2223" \
    -e TEST_PUBKEY="$(cat "$SSH_DIR/sb_test_key.pub" "$SSH_DIR/sb_phrase_key.pub")" \
    -e TEST_PHRASE_PUBKEY="$(cat "$SSH_DIR/sb_phrase_key.pub")" \
    -v "$FIX/ssh/sshd-setup.sh:/sshd-setup.sh:ro" -v "$SSH_DIR/hostkeys:/hostkeys:ro" \
    "$SSHD_IMG" sh /sshd-setup.sh >/dev/null
  # Docker accepts connections on a published port before anything listens behind it,
  # so wait for the two sshd processes themselves.
  wait_for "$SSHD" sh -c "[ \$(docker exec $SSHD sh -c 'ps | grep -c \"[s]shd.*-f /etc/ssh/sshd_\"') -ge 2 ]"
}

# The Unix-socket relay (scripts/fixtures/socket-relay.py), for as long as the tests run.
start_socket_relay() {
  python3 "$FIX/socket-relay.py" "$SOCK_DIR/mysql.sock=127.0.0.1:$MARIA_PORT" \
    "$SOCK_DIR/.s.PGSQL.$PG_PORT=127.0.0.1:$PG_PORT" >/dev/null &
  RELAY_PID=$!
  trap 'kill $RELAY_PID 2>/dev/null || true' EXIT
  wait_for "socket relay" test -S "$SOCK_DIR/.s.PGSQL.$PG_PORT"
}

seed() {
  need_docker
  say "Seeding fixtures"
  docker exec -i "$MARIA"  mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql";            ok "mariadb $MARIA_PORT  (sbtest/sbwrite/sbreal)"
  python3 "$FIX/bigschema.py" | docker exec -i "$MARIA" mysql -uroot -p"$MY_ROOT_PW";    ok "mariadb $MARIA_PORT  (sbbig: 3,275 tables)"
  docker exec -i "$MARIA2" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql";            ok "mariadb $MARIA2_PORT (second server for MultiServer)"
  docker exec -i "$PG" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$FIX/postgres.sql" >/dev/null; ok "postgres $PG_PORT (sbtest)"
  docker exec -i "$CH" clickhouse-client -u "$CH_USER" --password "$CH_PW" --multiquery < "$FIX/clickhouse.sql"; ok "clickhouse $CH_HTTP (sbtest.fleet_meta, default.events)"
  if docker ps --format '{{.Names}}' | grep -qx "$MYSQL8"; then
    docker exec -i "$MYSQL8" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"
    docker exec -i "$MYSQL8" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql8.sql"; ok "mysql 8.4 $MYSQL8_PORT (sbtest/sbwrite/sbreal, sbnative)"
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$MARIA11"; then
    docker exec -i "$MARIA11" mariadb -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"; ok "mariadb 11.4 $MARIA11_PORT (sbtest/sbwrite/sbreal)"
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$MYSQL80"; then
    docker exec -i "$MYSQL80" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql.sql"
    docker exec -i "$MYSQL80" mysql -uroot -p"$MY_ROOT_PW" < "$FIX/mysql8.sql"; ok "mysql 8.0 $MYSQL80_PORT (sbtest/sbwrite/sbreal, sbnative)"
  fi
}

teardown() {
  need_docker
  say "Tearing containers down"
  docker rm -f "$MARIA" "$MARIA2" "$MYSQL8" "$MARIA11" "$MYSQL80" "$PG" "$PGSSL" "$CH" "$SSHD" >/dev/null 2>&1 || true
  ok "removed $MARIA $MARIA2 $MYSQL8 $MARIA11 $MYSQL80 $PG $PGSSL $CH $SSHD"
}

# ---- the env every gated suite reads (TEST_RUNNER_ prefix stripped by Xcode)-
export_db_env() {
  # MySQL family: MySQLIntegration, QueryEngineDDL, PanelWritePath, RealSchema, MultiServer
  export TEST_RUNNER_SB_MYSQL_VERIFY=1
  export TEST_RUNNER_SB_MYSQL_HOST=127.0.0.1  TEST_RUNNER_SB_MYSQL_PORT=$MARIA_PORT
  export TEST_RUNNER_SB_MYSQL_PORT2=$MARIA2_PORT
  export TEST_RUNNER_SB_MYSQL_USER=root       TEST_RUNNER_SB_MYSQL_PASS=$MY_ROOT_PW
  export TEST_RUNNER_SB_MYSQL_DB=sbtest        TEST_RUNNER_SB_MYSQL_WRITE_DB=sbwrite  TEST_RUNNER_SB_MYSQL_REAL_DB=sbreal
  export TEST_RUNNER_SB_MYSQL_BIG_DB=sbbig     # MariaDB 10.0 only: 3,275 tables
  # Destructive DDL (the MySQL-family server above, db sbwrite)
  export TEST_RUNNER_SB_DDL_VERIFY=1
  # Cross-server JOIN reduction
  export TEST_RUNNER_SB_XJOIN_VERIFY=1
  export TEST_RUNNER_SB_XJOIN_HOST=127.0.0.1  TEST_RUNNER_SB_XJOIN_PORT=$MARIA_PORT
  export TEST_RUNNER_SB_XJOIN_USER=root       TEST_RUNNER_SB_XJOIN_PASS=$MY_ROOT_PW  TEST_RUNNER_SB_XJOIN_DB=sbtest
  # ClickHouse bridge (MariaDB attached side + ClickHouse bridged side)
  export TEST_RUNNER_SB_CHBRIDGE_VERIFY=1
  export TEST_RUNNER_SB_CHB_MY_HOST=127.0.0.1 TEST_RUNNER_SB_CHB_MY_PORT=$MARIA_PORT
  export TEST_RUNNER_SB_CHB_MY_USER=root      TEST_RUNNER_SB_CHB_MY_PASS=$MY_ROOT_PW
  export TEST_RUNNER_SB_CHB_CH_HOST=127.0.0.1 TEST_RUNNER_SB_CHB_CH_PORT=$CH_HTTP
  export TEST_RUNNER_SB_CHB_CH_USER=$CH_USER  TEST_RUNNER_SB_CHB_CH_PASS=$CH_PW      TEST_RUNNER_SB_CHB_DB=sbtest
  # ClickHouse native connection
  export TEST_RUNNER_SB_CH_VERIFY=1
  export TEST_RUNNER_SB_CH_HOST=127.0.0.1     TEST_RUNNER_SB_CH_PORT=$CH_HTTP
  export TEST_RUNNER_SB_CH_USER=$CH_USER      TEST_RUNNER_SB_CH_PASS=$CH_PW
  # PostgreSQL
  export TEST_RUNNER_SB_PG_VERIFY=1
  export TEST_RUNNER_SB_PG_HOST=127.0.0.1     TEST_RUNNER_SB_PG_PORT=$PG_PORT
  export TEST_RUNNER_SB_PG_USER=$PG_USER      TEST_RUNNER_SB_PG_PASS=$PG_PW          TEST_RUNNER_SB_PG_DB=$PG_DB
  # SSH tunnels (SSHTunnel, Connection types) and Unix sockets (Connection types)
  export TEST_RUNNER_SB_SSH_VERIFY=1          TEST_RUNNER_SB_SSH_KEY="$SSH_DIR/sb_test_key"
  export TEST_RUNNER_SB_SSH_PHRASE_KEY="$SSH_DIR/sb_phrase_key"
  export TEST_RUNNER_SB_SSH_PORT=$SSH_PORT    TEST_RUNNER_SB_SSH_LEGACY_PORT=$SSH_LEGACY_PORT
  export TEST_RUNNER_SB_SOCKET_VERIFY=1       TEST_RUNNER_SB_MYSQL_SOCKET="$SOCK_DIR/mysql.sock"
  export TEST_RUNNER_SB_PG_SOCKET_DIR="$SOCK_DIR"
  # MySQL 8.4: the client's own login (MySQL8Tests); the second pass below reuses the rest
  export TEST_RUNNER_SB_MYSQL8_VERIFY=1       TEST_RUNNER_SB_MYSQL8_PORT=$MYSQL8_PORT  TEST_RUNNER_SB_MYSQL8_PASS=$MY_ROOT_PW
  # Use SSL: MySQL 8.4 offers TLS; MariaDB 10.0 and PostgreSQL 16 here don't
  export TEST_RUNNER_SB_SSL_VERIFY=1          TEST_RUNNER_SB_SSL_TLS_PORT=$MYSQL8_PORT TEST_RUNNER_SB_SSL_PLAIN_PORT=$MARIA_PORT
  export TEST_RUNNER_SB_PG_SSL_PORT=$PGSSL_PORT
  if [ "$RUN_BENCH" = 1 ]; then
    export TEST_RUNNER_SB_BENCH=1 TEST_RUNNER_SB_BENCH_OUT="$ROOT/.build/sb_bench.json"
    [ "$CONFIG" = Release ] || warn "benchmark wants --release for honest numbers"
  fi
}

run_tests() {
  local xcflags=(-scheme SequelBridge -configuration "$CONFIG" -destination "$DESTINATION" -parallel-testing-enabled NO)
  local f; for f in $ONLY; do xcflags+=(-only-testing:"$f"); done
  if [ "$NO_BUILD" = 0 ]; then
    say "Building ($CONFIG)"
    xcodebuild build "${xcflags[@]}" | tail -1
  fi
  say "Testing ($CONFIG)"
  set +e
  # No `|| true` here: it would run as the last command and overwrite PIPESTATUS,
  # masking an xcodebuild failure. set +e already keeps a grep no-match from aborting.
  # "Executed N tests" counts XCTest cases only (always 0 here); the Swift Testing
  # summary is the "Test run with N tests …" line.
  xcodebuild test "${xcflags[@]}" 2>&1 | tee "$ROOT/.build/run-all-tests.log" | \
    grep -E "Test Suite .* (passed|failed)|Executed .* tests|Test run with|✘|error:|\*\* TEST"
  local rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

# The MySQL family suites again, with their server pointed at MySQL 8.4, MariaDB 11.4
# and MySQL 8.0 in turn. MariaDB 10.0 stays the second server, so MultiServer joins
# across versions.
MYSQL_SUITES=(MySQLIntegrationTests MySQLRelationsTests DatabaseSwitchTests ContentBrowseTests ServerToolsTests QueryTabAsTypedTests SSLConnectionTests QueryEngineDDLTests DatabaseDumpTests PanelWritePathTests ReadOnlyModeTests ReadOnlyMySQLTests MySQLNativeStatementTests MySQLScannerCacheTests MySQLRowWriteTests
              RealSchemaTests MultiServerTests DestructiveDDLVerifyTests QueryResultEditTests PostgresTests
              ClickHouseBridgeTests CrossEngineJoinTests CrossJoinReductionTests FallbackMaterializeDBTests
              QueryCancelTests PushdownDBTests)
run_mysql_pass() { # label port log-name
  local xcflags=(-scheme SequelBridge -configuration "$CONFIG" -destination "$DESTINATION" -parallel-testing-enabled NO)
  local s; for s in "${MYSQL_SUITES[@]}"; do xcflags+=(-only-testing:"SequelBridgeTests/$s"); done
  say "MySQL suites again, against $1 (:$2)"
  (
    export TEST_RUNNER_SB_MYSQL_PORT=$2  TEST_RUNNER_SB_MYSQL_PORT2=$MARIA_PORT
    export TEST_RUNNER_SB_XJOIN_PORT=$2  TEST_RUNNER_SB_CHB_MY_PORT=$2
    export TEST_RUNNER_SB_SSL_TLS_PORT=$2      # each of these servers offers TLS
    export TEST_RUNNER_SB_MYSQL_BIG_DB=        # the 3,275-table database is MariaDB 10.0's
    set +e
    xcodebuild test "${xcflags[@]}" 2>&1 | tee "$ROOT/.build/run-all-tests-$3.log" | \
      grep -E "Test run with|✘|error:|\*\* TEST"
    exit ${PIPESTATUS[0]}
  )
}

mkdir -p "$ROOT/.build"
case "$MODE" in
  down)      teardown; exit 0 ;;
  hermetic)  say "Hermetic unit tests only (no Docker, no gated suites)"; run_tests; exit $? ;;
  provision) provision ;;
  seed)      seed ;;
  run)       need_docker
             docker ps --format '{{.Names}}' | grep -qx "$MARIA" || { warn "containers not up — run with --provision first"; exit 1; } ;;
esac
# The SSH server and MySQL 8 are new in this setup, so a plain run starts them if missing.
docker ps --format '{{.Names}}' | grep -qx "$SSHD" || start_sshd
docker exec "$SSHD" id otpuser >/dev/null 2>&1 || start_sshd     # a server from before the one-time-code account
docker ps --format '{{.Names}}' | grep -qx "$MYSQL8" || start_mysql8
docker ps --format '{{.Names}}' | grep -qx "$MARIA11" || start_mariadb11
docker ps --format '{{.Names}}' | grep -qx "$MYSQL80" || start_mysql80
docker ps --format '{{.Names}}' | grep -qx "$PGSSL" || start_pgssl
start_socket_relay

export_db_env
if [ -n "$MYSQL_PORT_OVERRIDE" ]; then
  export TEST_RUNNER_SB_MYSQL_PORT=$MYSQL_PORT_OVERRIDE TEST_RUNNER_SB_XJOIN_PORT=$MYSQL_PORT_OVERRIDE
  export TEST_RUNNER_SB_CHB_MY_PORT=$MYSQL_PORT_OVERRIDE
  # Every server here but MariaDB 10.0 offers TLS: the SSL suite uses the one picked.
  [ "$MYSQL_PORT_OVERRIDE" != "$MARIA_PORT" ] && export TEST_RUNNER_SB_SSL_TLS_PORT=$MYSQL_PORT_OVERRIDE
  [ "$MYSQL_PORT_OVERRIDE" != "$MARIA_PORT" ] && export TEST_RUNNER_SB_MYSQL_BIG_DB=
fi
rc=0
run_tests || rc=1
if [ -z "$ONLY" ]; then
  run_mysql_pass "MySQL 8.4" "$MYSQL8_PORT" mysql8 || rc=1
  run_mysql_pass "MariaDB 11.4" "$MARIA11_PORT" mariadb11 || rc=1
  run_mysql_pass "MySQL 8.0" "$MYSQL80_PORT" mysql80 || rc=1
fi
if [ $rc = 0 ]; then
  say "ALL TESTS PASSED ($CONFIG, $DESTINATION, full matrix, MySQL suites on MariaDB 10.0 and 11.4, MySQL 8.4 and 8.0)"
else
  say "TEST FAILURES — see .build/run-all-tests*.log"; exit 1
fi
