#!/bin/bash
# check-docs.sh — every image and relative link in README.md and guide/*.md must exist,
# every in-page anchor must match a heading, and every guide image must be ≤ 400 KB.
# Exits 1 on the first problem. Run it before committing docs.
set -u
cd "$(dirname "$0")/.."
fail=0

anchors_of() {   # GitHub-style anchors of a markdown file's headings
  grep -E '^#{1,6} ' "$1" | sed -E 's/^#+ //' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
}

for f in README.md guide/*.md; do
  dir=$(dirname "$f")
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in http://*|https://*|mailto:*) continue ;; esac
    path="${target%%#*}"; anchor=""; [[ "$target" == *#* ]] && anchor="${target#*#}"
    if [ -n "$path" ]; then
      resolved="$dir/$path"
      if [ ! -e "$resolved" ] && [ ! -e "$path" ]; then
        case "$path" in ../../releases) continue ;; esac     # GitHub's own Releases page
        echo "$f: missing target $target"; fail=1; continue
      fi
      [ -e "$resolved" ] || resolved="$path"
    else
      resolved="$f"
    fi
    if [ -n "$anchor" ] && [[ "$resolved" == *.md ]]; then
      anchors_of "$resolved" | grep -qx "$anchor" || { echo "$f: no heading for anchor #$anchor in $resolved"; fail=1; }
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/ "[^"]*"$//')
done

for img in guide/images/*.png; do
  [ -e "$img" ] || continue
  size=$(stat -f%z "$img")
  [ "$size" -le 400000 ] || { echo "$img: $((size / 1024)) KB is over the 400 KB budget"; fail=1; }
done

# Every Mermaid diagram must render: GitHub shows nothing at all for one with a syntax
# error (a semicolon in a sequence-diagram message is enough). Needs mermaid-cli: `mmdc`
# on PATH, or MMDC=/path/to/mmdc. Uses the installed Chrome when there is one.
MMDC="${MMDC:-$(command -v mmdc || true)}"
if [ -n "$MMDC" ]; then
  tmp=$(mktemp -d)
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  pp=()
  if [ -x "$chrome" ]; then
    printf '{"executablePath":"%s","args":["--no-sandbox"]}\n' "$chrome" > "$tmp/puppeteer.json"
    pp=(-p "$tmp/puppeteer.json")
  fi
  for f in README.md guide/*.md; do
    awk -v d="$tmp" -v src="$(echo "$f" | tr '/.' '--')" \
      '/^```mermaid/{n++; out=sprintf("%s/%s-%d.mmd", d, src, n); p=1; next} /^```$/{p=0} p{print > out}' "$f"
  done
  for m in "$tmp"/*.mmd; do
    [ -e "$m" ] || continue
    if ! "$MMDC" "${pp[@]}" -q -i "$m" -o "${m%.mmd}.svg" >/dev/null 2>"$m.err"; then
      echo "$(basename "$m" .mmd): the Mermaid diagram does not render — $(grep -m1 -E 'Error' "$m.err")"; fail=1
    fi
  done
  rm -rf "$tmp"
else
  echo "mermaid: not checked (install @mermaid-js/mermaid-cli, or set MMDC)"
fi

[ $fail -eq 0 ] && echo "docs ok" || exit 1
