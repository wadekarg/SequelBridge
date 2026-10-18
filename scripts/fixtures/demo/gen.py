#!/usr/bin/env python3
"""Prints the demo dataset as SQL for one engine: gen.py mysql|postgres|clickhouse|sqlite.

Synthetic and deterministic (fixed seed), so every screenshot and the demo video show
the same rows. Loaded by scripts/seed-demo.sh into the local test containers."""
import datetime
import random
import sys

random.seed(20261012)
FIRST = ["Avery", "Blake", "Casey", "Dana", "Elliot", "Finley", "Harper", "Jordan", "Kai", "Logan", "Morgan", "Noor",
         "Parker", "Quinn", "Reese", "Rowan", "Sasha", "Taylor", "Umi", "Val"]
LAST = ["Chen", "Okafor", "Silva", "Novak", "Haddad", "Lindqvist", "Moreau", "Patel", "Rossi", "Sato", "Tanaka", "Varga",
        "Walsh", "Yilmaz", "Zhang", "Baker", "Costa", "Dubois", "Fischer", "Garcia"]
REGIONS = [("na-east", "North America East", "US", "America/New_York"),
           ("na-west", "North America West", "US", "America/Los_Angeles"),
           ("eu-west", "Europe West", "IE", "Europe/Dublin"),
           ("eu-central", "Europe Central", "DE", "Europe/Berlin"),
           ("apac-sg", "Asia Pacific", "SG", "Asia/Singapore"),
           ("latam", "Latin America", "BR", "America/Sao_Paulo")]
PLANS = ["free", "pro", "team", "enterprise"]
CATS = ["cables", "audio", "storage", "displays", "input", "power"]
N_CUSTOMERS, N_PRODUCTS, N_ORDERS = 2000, 120, 5000
START = datetime.date(2025, 1, 1)


def customers():
    for i in range(1, N_CUSTOMERS + 1):
        f, l = random.choice(FIRST), random.choice(LAST)
        yield (i, f"{f} {l}", f"{f.lower()}.{l.lower()}{i}@example.com", random.choice(REGIONS)[0],
               START + datetime.timedelta(days=random.randint(0, 600)), random.choice(PLANS))


def products():
    for i in range(1, N_PRODUCTS + 1):
        c = random.choice(CATS)
        yield (f"SKU-{i:04d}", f"{c.title()} item {i}", c, round(random.uniform(4, 400), 2))


def orders():
    for i in range(1, N_ORDERS + 1):
        placed = datetime.datetime(2025, 1, 1) + datetime.timedelta(minutes=random.randint(0, 600 * 1440))
        yield (i, random.randint(1, N_CUSTOMERS),
               random.choice(["paid", "paid", "paid", "shipped", "refunded", "pending"]), placed)


def items(order_ids):
    n = 1
    for oid in order_ids:
        for _ in range(random.randint(1, 6)):
            yield (n, oid, f"SKU-{random.randint(1, N_PRODUCTS):04d}", random.randint(1, 4))
            n += 1


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


def main(engine):
    out = []
    if engine == "mysql":
        out += ["CREATE DATABASE IF NOT EXISTS shopdemo; USE shopdemo;",
                "DROP TABLE IF EXISTS order_items; DROP TABLE IF EXISTS orders; DROP TABLE IF EXISTS products;",
                "CREATE TABLE products (sku VARCHAR(12) PRIMARY KEY, name VARCHAR(80), category VARCHAR(20), price DECIMAL(10,2));",
                "CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT NOT NULL, status VARCHAR(10), placed_at DATETIME, INDEX idx_customer (customer_id));",
                "CREATE TABLE order_items (id INT PRIMARY KEY, order_id INT NOT NULL, sku VARCHAR(12), qty INT, INDEX idx_order (order_id),"
                " CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders (id)) ENGINE=InnoDB;",
                "DROP PROCEDURE IF EXISTS top_customers;",
                "CREATE PROCEDURE top_customers(IN n INT) SELECT customer_id, COUNT(*) AS orders FROM orders GROUP BY customer_id ORDER BY orders DESC LIMIT n;"]
        out.append("INSERT INTO products VALUES " + ",".join(f"({q(s)},{q(n)},{q(c)},{p})" for s, n, c, p in products()) + ";")
        ords = list(orders())
        for i in range(0, len(ords), 500):
            out.append("INSERT INTO orders VALUES " + ",".join(
                f"({o},{c},{q(s)},{q(t.strftime('%Y-%m-%d %H:%M:%S'))})" for o, c, s, t in ords[i:i + 500]) + ";")
        its = list(items([o[0] for o in ords]))
        for i in range(0, len(its), 1000):
            out.append("INSERT INTO order_items VALUES " + ",".join(
                f"({n},{o},{q(s)},{qt})" for n, o, s, qt in its[i:i + 1000]) + ";")
    elif engine == "postgres":
        out += ["DROP TABLE IF EXISTS support_tickets; DROP TABLE IF EXISTS customers;",
                "CREATE TABLE customers (id INT PRIMARY KEY, full_name TEXT, email TEXT, region_code TEXT, signup_date DATE, plan TEXT);",
                "CREATE TABLE support_tickets (id INT PRIMARY KEY, customer_id INT, opened_at TIMESTAMP, priority TEXT, status TEXT);"]
        cs = list(customers())
        for i in range(0, len(cs), 500):
            out.append("INSERT INTO customers VALUES " + ",".join(
                f"({i_},{q(n)},{q(e)},{q(r)},{q(d)},{q(p)})" for i_, n, e, r, d, p in cs[i:i + 500]) + ";")
        out.append("INSERT INTO support_tickets VALUES " + ",".join(
            f"({t},{random.randint(1, N_CUSTOMERS)},"
            f"{q((datetime.datetime(2025, 1, 1) + datetime.timedelta(hours=random.randint(0, 14000))).strftime('%Y-%m-%d %H:%M:%S'))},"
            f"{q(random.choice(['low', 'normal', 'high']))},{q(random.choice(['open', 'closed', 'closed']))})"
            for t in range(1, 801)) + ";")
        out.append("CREATE OR REPLACE FUNCTION customer_display(n TEXT, e TEXT) RETURNS TEXT AS $$ SELECT n || ' <' || e || '>' $$ LANGUAGE SQL;")
        out.append("ANALYZE customers; ANALYZE support_tickets;")
    elif engine == "clickhouse":
        out += ["CREATE DATABASE IF NOT EXISTS analyticsdemo;",
                "DROP TABLE IF EXISTS analyticsdemo.events; DROP TABLE IF EXISTS analyticsdemo.daily_metrics;",
                "CREATE TABLE analyticsdemo.events (ts DateTime, customer_id UInt32, event LowCardinality(String), sku String, value Float64) ENGINE = MergeTree ORDER BY (customer_id, ts);",
                f"INSERT INTO analyticsdemo.events SELECT toDateTime('2025-01-01 00:00:00') + number * 36, 1 + (number * 7919) % {N_CUSTOMERS}, "
                f"['view','view','view','cart','purchase'][1 + number % 5], concat('SKU-', leftPad(toString(1 + number % {N_PRODUCTS}), 4, '0')), "
                f"round((number * 37 % 40000) / 100, 2) FROM numbers(1000000);",
                "CREATE TABLE analyticsdemo.daily_metrics (day Date, event LowCardinality(String), events UInt64, revenue Float64) ENGINE = MergeTree ORDER BY (day, event);",
                "INSERT INTO analyticsdemo.daily_metrics SELECT toDate(ts), event, count(), round(sum(value), 2) FROM analyticsdemo.events GROUP BY toDate(ts), event;"]
    elif engine == "sqlite":
        out += ["DROP TABLE IF EXISTS regions; DROP TABLE IF EXISTS currencies;",
                "CREATE TABLE regions (code TEXT PRIMARY KEY, name TEXT, country TEXT, timezone TEXT);",
                "CREATE TABLE currencies (country TEXT PRIMARY KEY, currency TEXT, symbol TEXT);",
                "INSERT INTO regions VALUES " + ",".join(f"({q(c)},{q(n)},{q(k)},{q(t)})" for c, n, k, t in REGIONS) + ";",
                "INSERT INTO currencies VALUES ('US','USD','$'),('IE','EUR','€'),('DE','EUR','€'),('SG','SGD','S$'),('BR','BRL','R$');"]
    else:
        sys.exit("usage: gen.py mysql|postgres|clickhouse|sqlite")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "")
