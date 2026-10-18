-- SequelBridge test fixtures — PostgreSQL
-- Seeds what the gated PostgreSQL + cross-engine suites assume:
--   sbtest.big_metrics  (500 tails N000SB..N499SB × 200 rows = 100000) — CrossEngineBenchmark, cross-engine JOIN
--   sbtest.small_fleet  (10 rows, tails ⊂ big_metrics)
--   sbtest.customers/orders/order_items                                 — PostgresTests (joins)
--
-- Idempotent and deterministic (setseed) so comparisons are stable.

CREATE SCHEMA IF NOT EXISTS public;

-- ---- big_metrics : 500 tails × 200 rows -----------------------------------
DROP TABLE IF EXISTS big_metrics;
CREATE TABLE big_metrics (
  id        INTEGER PRIMARY KEY,
  tail      TEXT,
  metric_ts TIMESTAMP,
  score     NUMERIC
);
INSERT INTO big_metrics (id, tail, metric_ts, score)
SELECT g,
       'N' || lpad((g / 200)::text, 3, '0') || 'SB',
       TIMESTAMP '2026-01-01 00:00:00' + ((g % 200) * INTERVAL '1 minute'),
       round((((g * 2654435761) % 100000) / 100.0)::numeric, 3)
FROM generate_series(0, 99999) AS g;   -- 500 tails (g/200) × 200 rows each

-- ---- small_fleet ----------------------------------------------------------
DROP TABLE IF EXISTS small_fleet;
CREATE TABLE small_fleet (id INTEGER, tail TEXT, status TEXT);
INSERT INTO small_fleet (id, tail, status)
SELECT g + 1, 'N' || lpad(g::text, 3, '0') || 'SB', 'active'
FROM generate_series(0, 9) AS g;

-- ---- customers / orders / order_items -------------------------------------
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

-- Column set, types, named index/constraint all mirror the MySQL fixture so the
-- metadata suites (PostgresMetadataTests) see the same shapes on both engines.
CREATE TABLE customers (
  id           SERIAL PRIMARY KEY,
  email        VARCHAR(255) NOT NULL,
  full_name    VARCHAR(120),
  credit_limit NUMERIC(10,2) DEFAULT 0.00,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  signup_date  DATE,
  created_at   TIMESTAMP DEFAULT now(),
  notes        TEXT,
  avatar       BYTEA,
  CONSTRAINT uq_customers_email UNIQUE (email)
);
CREATE INDEX idx_customers_name_date ON customers (full_name, signup_date);
INSERT INTO customers (email, full_name, credit_limit, is_active, signup_date, notes) VALUES
  ('a@x.com', 'Ada Lovelace', 500.00,  TRUE, '2026-01-15', 'first'),
  ('b@x.com', 'Alan Turing',  1200.50, TRUE, '2026-02-20', NULL),
  ('c@x.com', NULL,           0.00,    TRUE, NULL,         'no name');

CREATE TABLE orders (
  id          BIGSERIAL PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  total       DOUBLE PRECISION,
  status      TEXT DEFAULT 'new',
  placed_at   TIMESTAMP NOT NULL DEFAULT now(),
  -- ON UPDATE RESTRICT is explicit: Postgres reports an unspecified action as
  -- "NO ACTION", where MySQL implies "RESTRICT"; declaring it makes both engines agree.
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
    ON DELETE CASCADE ON UPDATE RESTRICT
);
INSERT INTO orders (customer_id, total, status) VALUES
  (1, 99.99,  'paid'),
  (1, 10,     'new'),
  (2, 250.75, 'shipped');

CREATE TABLE order_items (
  order_id BIGINT NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  line_no  SMALLINT NOT NULL,
  sku      TEXT NOT NULL,
  qty      INTEGER DEFAULT 1,
  PRIMARY KEY (order_id, line_no)
);
INSERT INTO order_items (order_id, line_no, sku, qty) VALUES
  (1, 1, 'SKU-A', 2),
  (1, 2, 'SKU-B', 1),
  (2, 1, 'SKU-C', 5);

-- ---- a non-public schema : the app surfaces PG schemas as "databases" --------
DROP SCHEMA IF EXISTS reporting CASCADE;
CREATE SCHEMA reporting;
CREATE TABLE reporting.daily_totals (
  day   DATE PRIMARY KEY,
  total NUMERIC(12,2) NOT NULL
);
INSERT INTO reporting.daily_totals (day, total) VALUES ('2026-01-01', 1234.56);
