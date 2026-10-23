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
build it yourself (another version of DuckDB or of a library it links), you need Xcode's
command-line tools, CMake and Ninja. A Mac with Apple Silicon builds both CPUs, as CI
does (`.github/workflows/build-duckdb.yml`); an Intel Mac builds x86_64:

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
extension list are in `vendor/DuckDB/recipe/`. The drivers are linked into one binary, so
the build stops if two of them define one name two ways (`scripts/check-driver-symbols.sh`).

To build the app with your own version of a library DuckDB links, such as MariaDB
Connector/C (LGPL; the source the package was built from is in its `sources/` folder),
build it as a static library for the app's CPUs, compatible with the version shipped (the
drivers were compiled against its headers), put it in `vendor/DuckDB/libs` in place of
the one there (`libmariadbclient.a`), and build the app: it links what that folder holds.

### The App Store build

The `SequelBridgeAppStore` scheme builds the same app for the Mac App Store: in the App
Sandbox, without Sparkle (see [Two builds](guide/ARCHITECTURE.md#two-builds)). Both
targets make `SequelBridge.app`, so build it in derived data of its own, or it replaces
the DMG build's app in Xcode's:

```bash
xcodebuild build -scheme SequelBridgeAppStore -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Caches/SequelBridge-appstore/dd
scripts/test-appstore-build.sh       # both builds, each checked
scripts/check-appstore-sandbox.sh    # its SSH and SQLite code in the sandbox (the test SSH server up)
```

Code only one build may have sits under `#if APP_STORE` or `#if !APP_STORE`; what differs
at run time asks `Distribution.current`. The two share a bundle id, and macOS may open a
build in place of the copy in Applications: `scripts/forget-builds.sh <folder>` makes it
forget the apps in a folder (the scripts above do it for theirs).

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
