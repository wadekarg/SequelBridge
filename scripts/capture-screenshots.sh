#!/bin/bash
# capture-screenshots.sh [--scene NAME] — regenerates guide/images/*.png from a demo
# instance of the app: a renamed Release copy launched on the fixture connection list
# (scripts/fixtures/demo-connections.json) against the synthetic demo data
# (scripts/seed-demo.sh). Refuses to capture unless Home shows exactly the four demo
# connections. Light theme, 1440×840 window, seven images, each ≤ 400 KB.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/screenshots/lib.sh
OUT=guide/images; RAW=/tmp/sb-shots-raw; mkdir -p "$OUT" "$RAW"
ONLY=""; [ "${1:-}" = "--scene" ] && ONLY="${2:-}"
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
finish() { python3 scripts/screenshots/postprocess.py "$RAW/$1.png" "$OUT/$1.png"; }

shots_build
shots_launch Light
shots_guard

# Home list rows (screen coordinates): the "Demo" folder header puts the first row at
# y=302, then 48 px per row; the checkbox is at x=213. Connect is at (496,945).
ROW_Y=(302 351 398 446)
scene_home() {    # Home with the four demo connections, two ticked (and unticked again afterwards)
  gclick 213 ${ROW_Y[0]}; sleep 0.3; gclick 213 ${ROW_Y[1]}; sleep 0.6
  capture_window "$RAW/home.png"; finish home
  gclick 213 ${ROW_Y[0]}; sleep 0.3; gclick 213 ${ROW_Y[1]}; sleep 0.3
}

# Workspace coordinates (screen): toolbar Run button, the sidebar's table list (first
# row y=315, 32 px per row, x=241), and the results footer's grid/chart toggles.
RUN_X=1565; RUN_Y=199
TABLE_X=241; TABLE_Y0=315; TABLE_PITCH=32
CHART_X=1315; GRID_X=1285; FOOTER_Y=954

connect_all() {   # tick the four rows, Connect, wait for the workspace, land on the Query tab
  for y in "${ROW_Y[@]}"; do gclick 213 "$y"; sleep 0.3; done
  gclick 496 945; sleep 10
  ax_click_tab "Query"
}
run_sql() {       # $1 = sql, $2 = max seconds: fill the editor, click Run, wait for the rows
  ax_set_editor "$1"; gclick $RUN_X $RUN_Y; wait_rows "${2:-120}"
}
select_table() {  # $1 = row index in the sidebar's table list (sorted by name)
  gclick $TABLE_X $((TABLE_Y0 + $1 * TABLE_PITCH)); sleep 1.5
}

scene_hero() {              # the three-engine query (MySQL × PostgreSQL × SQLite) with its results
  run_sql "$(cat scripts/screenshots/hero.sql)" 180
  capture_window "$RAW/hero.png"; finish hero
}
scene_cross_engine_join() { # the two-table join that streams server to server
  run_sql "$(cat scripts/screenshots/cross-engine-join.sql)" 120
  capture_window "$RAW/cross-engine-join.png"; finish cross-engine-join
}
scene_chart() {             # a ClickHouse query shown as a chart (monthly: fourteen readable bars)
  run_sql "SELECT formatDateTime(day, '%Y-%m') AS month, round(sum(revenue)) AS revenue FROM analytics.daily_metrics WHERE event = 'purchase' GROUP BY month ORDER BY month" 60
  gclick $CHART_X $FOOTER_Y; sleep 1.5
  capture_window "$RAW/chart.png"; finish chart
  gclick $GRID_X $FOOTER_Y; sleep 0.5
}
scene_table_panel() {       # $1 = tab title, $2 = scene name (a table must be selected)
  ax_click_tab "$1"; sleep 2.5; capture_window "$RAW/$2.png"; finish "$2"
}
scene_console()  { ax_click_tab "Console";  sleep 1.5; capture_window "$RAW/console.png";  finish console; }

want home && scene_home
connect_all
want hero && scene_hero
want cross-engine-join && scene_cross_engine_join
want chart && scene_chart
select_table 1                              # Shop's tables sorted by name: order_items, orders, products
want structure && scene_table_panel "Structure" structure
want content   && scene_table_panel "Content"   content
want console   && scene_console
[ "${SB_SHOTS_KEEP:-0}" = "1" ] || shots_quit     # SB_SHOTS_KEEP=1 leaves the instance open for probing
echo "done"
