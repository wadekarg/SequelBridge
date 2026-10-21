#!/usr/bin/env python3
# bigschema.py — a database the size of a real one: 3,274 MyISAM tables plus one with
# rows, latin1, as on an old MariaDB 10.0 production server. Through DuckDB the first
# Content edit there read the column list of every table first (16 s on a local
# container), so the row-write test times an edit against it. Piped into MariaDB 10.0
# by scripts/run-all-tests.sh.
print("DROP DATABASE IF EXISTS sbbig; CREATE DATABASE sbbig CHARACTER SET latin1; USE sbbig;")
for i in range(3274):
    print(f"CREATE TABLE t{i:04d} (id INT PRIMARY KEY, a VARCHAR(40), b INT, c DATETIME, d TEXT) ENGINE=MyISAM;")
print("CREATE TABLE sla_like (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(120), "
      "cause_category_id INT NULL, priority INT NULL) ENGINE=MyISAM DEFAULT CHARSET=latin1;")
print("INSERT INTO sla_like (name) VALUES " + ",".join(f"('row {i}')" for i in range(1, 12)) + ";")
