-- SequelBridge test fixtures — MariaDB/MySQL
-- Seeds the exact tables the gated real-DB suites assume pre-existing:
--   sbtest.big_events   (500 tails N000SB..N499SB × 400 rows = 200000) — CrossJoinReduction, ClickHouseBridge, CrossEngineBenchmark
--   sbtest.small_fleet  (10 rows, tails N000SB..N009SB ⊂ big_events)   — CrossJoinReduction probe side
--   sbtest.customers/orders/order_items                                 — MySQLIntegration (FK + joins)
--   sbwrite             (empty DB; the write/DDL suites create their own tables)
--   sbreal.legacy_notes (MyISAM, zero-date timestamp)        — RealSchema (production schema shapes)
--
-- Idempotent: safe to re-run. Deterministic data (RAND is seeded) so "reduced == scanner"
-- comparisons are stable. Generated purely from SQL so no external data file is needed.

-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS sbtest  DEFAULT CHARSET=latin1;
CREATE DATABASE IF NOT EXISTS sbwrite DEFAULT CHARSET=utf8mb4;
CREATE DATABASE IF NOT EXISTS sbreal  DEFAULT CHARSET=latin1;

-- ---- sbtest: a 0..9 seed used to synthesize the big tables -----------------
USE sbtest;
CREATE TABLE IF NOT EXISTS seed10 (n INT NOT NULL, PRIMARY KEY (n)) ENGINE=InnoDB;
INSERT IGNORE INTO seed10 (n) VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

-- ---- sbtest.big_events : 500 tails × 400 rows -----------------------------
DROP TABLE IF EXISTS big_events;
CREATE TABLE big_events (
  `id`       INT(11)      NOT NULL AUTO_INCREMENT,
  `tail`     VARCHAR(8)   NOT NULL,
  `event_ts` DATETIME     NOT NULL,
  `value`    DOUBLE       NOT NULL,
  `note`     VARCHAR(60)  NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_tail` (`tail`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- t.n = 0..999 (we take <500 as tails), r.n = 0..999 (we take <400 as rows per tail)
INSERT INTO big_events (tail, event_ts, value, note)
SELECT CONCAT('N', LPAD(t.n, 3, '0'), 'SB'),
       TIMESTAMP('2026-01-01 00:00:00') + INTERVAL r.n MINUTE,
       ROUND(RAND(t.n * 400 + r.n) * 1000, 3),
       CONCAT('auto event #', r.n)
FROM   (SELECT a.n + b.n*10 + c.n*100 AS n FROM seed10 a, seed10 b, seed10 c) t
JOIN   (SELECT a.n + b.n*10 + c.n*100 AS n FROM seed10 a, seed10 b, seed10 c) r
WHERE  t.n < 500 AND r.n < 400;

-- ---- sbtest.small_fleet : 10-row probe, tails ⊂ big_events ----------------
DROP TABLE IF EXISTS small_fleet;
CREATE TABLE small_fleet (
  `id`     INT(11)     DEFAULT NULL,
  `tail`   VARCHAR(8)  DEFAULT NULL,
  `status` VARCHAR(10) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
INSERT INTO small_fleet (id, tail, status)
SELECT n + 1, CONCAT('N', LPAD(n, 3, '0'), 'SB'), 'active' FROM seed10;

-- ---- sbtest.customers / orders / order_items : FK + join fixtures ---------
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
  `id`           INT(11)       NOT NULL AUTO_INCREMENT,
  `email`        VARCHAR(255)  NOT NULL,
  `full_name`    VARCHAR(120)  DEFAULT NULL,
  `credit_limit` DECIMAL(10,2) DEFAULT '0.00',
  `is_active`    TINYINT(1)    NOT NULL DEFAULT '1',
  `signup_date`  DATE          DEFAULT NULL,
  `created_at`   DATETIME      DEFAULT CURRENT_TIMESTAMP,
  `notes`        TEXT,
  `avatar`       BLOB,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_customers_email` (`email`(191)),
  KEY `idx_customers_name_date` (`full_name`, `signup_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO customers (id, email, full_name, credit_limit, is_active, signup_date, notes) VALUES
  (1, 'a@x.com', 'Ada Lovelace', 500.00,  1, '2026-01-15', 'first'),
  (2, 'b@x.com', 'Alan Turing',  1200.50, 1, '2026-02-20', NULL),
  (3, 'c@x.com', NULL,           0.00,    1, NULL,         'no name');

CREATE TABLE orders (
  `id`          BIGINT(20) NOT NULL AUTO_INCREMENT,
  `customer_id` INT(11)    NOT NULL,
  `total`       DOUBLE     DEFAULT NULL,
  `status`      ENUM('new','paid','shipped') DEFAULT 'new',
  `placed_at`   TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `fk_orders_customer` (`customer_id`),
  CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO orders (id, customer_id, total, status) VALUES
  (1, 1, 99.99,  'paid'),
  (2, 1, 10,     'new'),
  (3, 2, 250.75, 'shipped');

CREATE TABLE order_items (
  `order_id` BIGINT(20)  NOT NULL,
  `line_no`  SMALLINT(6) NOT NULL,
  `sku`      VARCHAR(64) NOT NULL,
  `qty`      INT(11)     DEFAULT '1',
  PRIMARY KEY (`order_id`, `line_no`),
  CONSTRAINT `fk_items_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO order_items (order_id, line_no, sku, qty) VALUES
  (1, 1, 'SKU-A', 2),
  (1, 2, 'SKU-B', 1),
  (2, 1, 'SKU-C', 5);

-- A BEFORE INSERT trigger on orders (customers has none) — the triggers panel suite.
DROP TRIGGER IF EXISTS trg_orders_before_insert;
CREATE TRIGGER trg_orders_before_insert BEFORE INSERT ON orders
  FOR EACH ROW SET NEW.status = IFNULL(NEW.status, 'new');

-- ---- sbreal.legacy_notes : production MyISAM / zero-date shape --
-- Mirrors a real production table: MyISAM, latin1, a zero-date default timestamp
-- and ON UPDATE CURRENT_TIMESTAMP — the shapes RealSchemaTests guards against.
USE sbreal;
SET @old_sql_mode = @@SESSION.sql_mode;
SET SESSION sql_mode = '';            -- allow the '0000-00-00' default on strict builds
DROP TABLE IF EXISTS legacy_notes;
CREATE TABLE legacy_notes (
  `id`           INT(11)      NOT NULL AUTO_INCREMENT,
  `note`         VARCHAR(1000) NOT NULL,
  `user`         VARCHAR(50)  NOT NULL,
  `dlt_flg`      VARCHAR(2)   NOT NULL DEFAULT 'N',
  `create_ts`    TIMESTAMP    NOT NULL DEFAULT '0000-00-00 00:00:00',
  `last_updt_ts` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `note` (`note`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
INSERT INTO legacy_notes (note, user, dlt_flg, create_ts) VALUES
  ('ground stop review',  'ops_user', 'N', '0000-00-00 00:00:00'),
  ('wx hold',             'ops_user', 'N', '2026-03-01 12:00:00'),
  ('deferred maintenance','ops_user', 'Y', '0000-00-00 00:00:00');
SET SESSION sql_mode = @old_sql_mode;
