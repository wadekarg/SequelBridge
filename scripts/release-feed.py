#!/usr/bin/env python3
"""release-feed.py — the two files a release publishes beside its DMG on GitHub Releases:
appcast.xml, the feed the app's updater (Sparkle) reads to offer the new version, and
sequelbridge.rb, the Homebrew cask (`brew install --cask wadekarg/tap/sequelbridge`).

  release-feed.py --version 1.2.2 --build 96 --dmg .build/release/SequelBridge-1.2.2.dmg \\
      --signature 'sparkle:edSignature="…" length="…"' [--changelog CHANGELOG.md] --out DIR

--signature is what vendor/Sparkle/bin/sign_update prints for the DMG. The release notes
are the version's section of CHANGELOG.md. The app finds the feed at
releases/latest/download/appcast.xml (Info.plist's SUFeedURL), so each release's own
appcast.xml names that release."""
import argparse
import hashlib
import html
import os
import re
from email.utils import formatdate

REPO = "https://github.com/wadekarg/SequelBridge"
MIN_MACOS = "14.0"          # the app's MACOSX_DEPLOYMENT_TARGET
CASK_MACOS = ":sonoma"      # macOS 14 or later, as Homebrew writes it


def inline(text):
    """A line of a note, escaped for HTML, with `code` kept as code and **bold** as bold
    (the update window showed the asterisks)."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", out)


def release_notes(changelog, version):
    """The version's section of the changelog as HTML: ### headings, - items (an item
    goes on over the indented lines after it), and an item's own list, "  - " items."""
    lines = open(changelog, encoding="utf-8").read().splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(rf"^##\s+{re.escape(version)}\b", l)), None)
    if start is None:
        return ""
    body = []
    for line in lines[start + 1:]:
        if line.startswith("## "):
            break
        body.append(line)
    parts, items = [], []   # each item: [its text, its own list's items]

    def sublist(children):
        return "<ul>" + "".join(f"<li>{inline(c)}</li>" for c in children) + "</ul>" if children else ""

    def close_list():
        if items:
            parts.append("<ul>" + "".join(f"<li>{inline(text)}{sublist(children)}</li>" for text, children in items) + "</ul>")
            items.clear()

    for line in body:
        if line.startswith("### "):
            close_list()
            parts.append(f"<h3>{inline(line[4:].strip())}</h3>")
        elif line.startswith("- "):
            items.append([line[2:].strip(), []])
        elif re.match(r" +- ", line) and items:
            items[-1][1].append(line.strip()[2:].strip())
        elif line.startswith(" ") and line.strip() and items:
            # The line goes on the item it follows: its own list's last item, if it has one.
            if items[-1][1]:
                items[-1][1][-1] += " " + line.strip()
            else:
                items[-1][0] += " " + line.strip()
        elif line.strip():
            close_list()
            parts.append(f"<p>{inline(line.strip())}</p>")
    close_list()
    return "".join(parts)


def appcast(version, build, signature, notes, url=None):
    url = url or f"{REPO}/releases/download/v{version}/SequelBridge-{version}.dmg"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SequelBridge</title>
    <link>{REPO}</link>
    <item>
      <title>SequelBridge {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_MACOS}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{REPO}/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""


def cask(version, sha256):
    return f"""cask "sequelbridge" do
  version "{version}"
  sha256 "{sha256}"

  url "{REPO}/releases/download/v#{{version}}/SequelBridge-#{{version}}.dmg"
  name "SequelBridge"
  desc "Query MySQL, PostgreSQL, SQLite and ClickHouse, and join across them"
  homepage "{REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: {CASK_MACOS}

  app "SequelBridge.app"

  zap trash: [
    "~/Library/Application Support/SequelBridge",
    "~/Library/Caches/SequelBridge",
    "~/Library/Preferences/gwadekar.SequelBridge.plist",
  ]
end
"""


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--dmg", required=True)
    p.add_argument("--signature", required=True, help="what sign_update prints for the DMG")
    p.add_argument("--changelog", default="CHANGELOG.md")
    p.add_argument("--out", required=True)
    p.add_argument("--download-url", help="the update's URL, for a feed served locally (the updater's own check)")
    a = p.parse_args()
    if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', a.signature.strip()):
        p.error(f"--signature isn't what sign_update prints: {a.signature!r}")
    sha256 = hashlib.sha256(open(a.dmg, "rb").read()).hexdigest()
    notes = release_notes(a.changelog, a.version).replace("]]>", "]]&gt;")
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "appcast.xml"), "w", encoding="utf-8") as f:
        f.write(appcast(a.version, a.build, a.signature.strip(), notes, a.download_url))
    with open(os.path.join(a.out, "sequelbridge.rb"), "w", encoding="utf-8") as f:
        f.write(cask(a.version, sha256))
    print(os.path.join(a.out, "appcast.xml"))
    print(os.path.join(a.out, "sequelbridge.rb"))


if __name__ == "__main__":
    main()
