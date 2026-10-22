# Contributing

Thanks for looking. Issues and pull requests are welcome; for anything larger than a
fix, open an issue first so we can agree on the approach before you spend time on it.

## Build

```bash
git clone https://github.com/wadekarg/SequelBridge.git
cd SequelBridge
scripts/fetch-duckdb.sh        # DuckDB with its drivers built in (once, not in git)
open SequelBridge.xcodeproj    # Build & Run in Xcode
```

The app links DuckDB statically, with the MySQL, PostgreSQL and SQLite drivers built in.
Nothing else to install.

### DuckDB from source

`scripts/fetch-duckdb.sh` installs a published build of DuckDB with the drivers, from
[sequelbridge-duckdb](https://github.com/wadekarg/sequelbridge-duckdb)'s releases. To
build it yourself (another version of DuckDB or of a library it links, such as MariaDB
Connector/C), you need Xcode's command-line tools, CMake and Ninja:

```bash
scripts/build-duckdb.sh arm64        # about 40 minutes a CPU the first time
scripts/build-duckdb.sh x86_64
scripts/package-duckdb.sh            # both CPUs in one zip, and its SHA-256
SB_DUCKDB_ZIP=~/Library/Caches/SequelBridge-duckdb-build/duckdb-v1.5.6-sb1-macos-universal.zip \
  scripts/fetch-duckdb.sh
python3 scripts/acknowledgements.py  # Help → Acknowledgements, if a license changed
```

`scripts/package-duckdb.sh --single x86_64` packages one CPU's build, to try it on that
Mac. The versions are pinned in `build-duckdb.sh`, and its patches, vcpkg triplets and
extension list are in `vendor/DuckDB/recipe/`. vcpkg builds the drivers' libraries from
its ports: to use your own version of one, give vcpkg an overlay port
(`VCPKG_OVERLAY_PORTS=/path/to/ports scripts/build-duckdb.sh …`).

## Test

```bash
scripts/run-all-tests.sh --hermetic     # unit tests, no Docker, about two minutes
scripts/run-all-tests.sh                # the full matrix against local containers
scripts/run-all-tests.sh --provision    # the same from scratch: fresh containers, seeded
```

The full matrix needs Docker. The script starts MariaDB (10.0, 11.4), MySQL (8.0, 8.4),
PostgreSQL (with and without TLS), ClickHouse and SSH server containers, seeds them from
`scripts/fixtures/`, and runs every gated suite against them. [TESTING.md](TESTING.md)
explains what each suite covers and how the gates work.

## What a change needs

- **A test that fails before the change and passes after it.** Every behaviour in the
  app has one; yours should too. A planner change that makes a query faster needs an
  equivalence test as well: the optimized plan must return exactly the rows the plain
  plan returns.
- **The hermetic suite green**, and the full matrix green if the change touches an
  engine, the planner or a panel's write path.
- **Docs that match.** The guide pages in `guide/` describe behaviour, not intentions;
  if you change what a feature does, change the page. `scripts/check-docs.sh` checks
  links, anchors and image sizes, and with mermaid-cli installed
  (`npm i -g @mermaid-js/mermaid-cli`) that every diagram renders: GitHub shows
  nothing at all for a diagram with a syntax error.
- **No real data.** Fixtures, tests and screenshots use the synthetic datasets in
  `scripts/fixtures/`. Screenshots come from `scripts/capture-screenshots.sh`, which
  refuses to run against anything but the demo connections.

## Pull requests

Keep them small and focused, one change per PR, with the test in the same commit as
the code it covers. Say in the description what a user would notice. The commit
message's first line is a short sentence in the present tense.
