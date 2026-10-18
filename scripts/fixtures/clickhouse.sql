-- SequelBridge test fixtures — ClickHouse
-- Seeds what the gated ClickHouse suites assume:
--   sbtest.fleet_meta  (10 typed rows, tails N000SB..N009SB) — ClickHouseBridge (the bridged side)
--                       Exercises the tricky type maps: IPv4/IPv6, UUID, DateTime64,
--                       Decimal, Int256, LowCardinality, Nullable, Array, Enum8.
--   default.events     (typed rows)                          — ClickHouseTests (native HTTP path)
--
-- Idempotent: CREATE DATABASE/TABLE IF NOT EXISTS, and the data inserts are truncated first.

CREATE DATABASE IF NOT EXISTS sbtest;

CREATE TABLE IF NOT EXISTS sbtest.fleet_meta
(
    `tail`     String,
    `ip`       IPv4,
    `ip6`      IPv6,
    `uid`      UUID,
    `reg_ts`   DateTime64(3),
    `price`    Decimal(10, 2),
    `big_num`  Int256,
    `lc`       LowCardinality(String),
    `maybe_dt` Nullable(DateTime),
    `tags`     Array(Int32),
    `status`   Enum8('active' = 1, 'inactive' = 2)
)
ENGINE = MergeTree
ORDER BY tail;

TRUNCATE TABLE sbtest.fleet_meta;
INSERT INTO sbtest.fleet_meta
    (tail, ip, ip6, uid, reg_ts, price, big_num, lc, maybe_dt, tags, status)
SELECT
    concat('N', leftPad(toString(number), 3, '0'), 'SB')                AS tail,
    toIPv4(concat('10.0.0.', toString(number + 1)))                     AS ip,
    toIPv6('2001:db8::1')                                               AS ip6,
    generateUUIDv4()                                                    AS uid,
    toDateTime64('2026-10-01 17:53:09.676', 3)                         AS reg_ts,
    toDecimal64(number * 10.5, 2)                                       AS price,
    toInt256(number) * 1000000000000000                                 AS big_num,
    ['alpha', 'beta', 'gamma'][(number % 3) + 1]                        AS lc,
    if(number % 2 = 0, toDateTime('2026-10-01 17:53:09'), NULL)         AS maybe_dt,
    [toInt32(number), toInt32(number + 1)]                              AS tags,
    if(number % 2 = 0, 'active', 'inactive')                            AS status
FROM numbers(10);

CREATE DATABASE IF NOT EXISTS default;
CREATE TABLE IF NOT EXISTS default.events
(
    `id`    UInt32,
    `tail`  String,
    `value` Float64
)
ENGINE = MergeTree
ORDER BY id;

-- Exactly 3 rows; ORDER BY id, row[0] == (1, 'N001SB', 9.5) — ClickHouseTests.queries().
TRUNCATE TABLE default.events;
INSERT INTO default.events (id, tail, value) VALUES
  (1, 'N001SB', 9.5),
  (2, 'N002SB', 19.5),
  (3, 'N003SB', 29.5);
