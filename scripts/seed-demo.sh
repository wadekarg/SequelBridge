#!/bin/bash
# seed-demo.sh — loads the synthetic demo dataset (guide screenshots, demo video)
# into the local test containers, in their own databases, and writes the SQLite file.
# Deterministic: every run produces the same rows. Needs the containers from
# scripts/run-all-tests.sh (--provision) to be running.
set -euo pipefail
cd "$(dirname "$0")/.."
GEN=scripts/fixtures/demo/gen.py
REF=scripts/fixtures/demo/ref.sqlite

echo "shop (MariaDB :3309, shopdemo)"
python3 "$GEN" mysql | docker exec -i sb-mariadb10 mysql -uroot -psbverify123

echo "crm (PostgreSQL :5433, crmdemo)"
if ! docker exec sb-postgres psql -U sbuser -d sbtest -tAc "SELECT 1 FROM pg_database WHERE datname='crmdemo'" | grep -q 1; then
  docker exec sb-postgres psql -U sbuser -d sbtest -qc "CREATE DATABASE crmdemo"
fi
python3 "$GEN" postgres | docker exec -i sb-postgres psql -U sbuser -d crmdemo -q

echo "analytics (ClickHouse :8123, analyticsdemo)"
python3 "$GEN" clickhouse | docker exec -i sb-clickhouse clickhouse-client --password sbpass123 --multiquery

echo "ref (SQLite file $REF)"
rm -f "$REF"
python3 "$GEN" sqlite | python3 -c "import sqlite3, sys; c = sqlite3.connect('$REF'); c.executescript(sys.stdin.read()); c.commit()"

echo "counts:"
docker exec sb-mariadb10 mysql -uroot -psbverify123 -N -e "SELECT 'orders', COUNT(*) FROM shopdemo.orders UNION ALL SELECT 'order_items', COUNT(*) FROM shopdemo.order_items" 2>/dev/null
docker exec sb-postgres psql -U sbuser -d crmdemo -tAc "SELECT 'customers ' || COUNT(*) FROM customers"
curl -s 'http://127.0.0.1:8123/?user=sbuser&password=sbpass123' --data "SELECT 'events', count() FROM analyticsdemo.events"; echo
python3 -c "import sqlite3; print('regions', sqlite3.connect('$REF').execute('select count(*) from regions').fetchone()[0])"
