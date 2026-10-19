// GET /download -> 302 straight to the .dmg of the newest GitHub release.
//
// The asset name carries the version (SequelBridge-1.2.1.dmg, see
// scripts/build-release.sh), so GitHub's /releases/latest/download/<name> link
// can't be used. The GitHub API is no good either: anonymous calls from
// Cloudflare's shared IPs get 403 (rate limit). Instead:
//   1. /releases/latest redirects to /releases/tag/vX.Y.Z  -> read the tag
//   2. build  /releases/download/vX.Y.Z/SequelBridge-X.Y.Z.dmg
//   3. check it exists, cache the answer for 10 minutes
// Any failure falls back to the releases page, with the reason in a header.

const REPO = "wadekarg/SequelBridge";
const GH = `https://github.com/${REPO}`;
const FALLBACK = `${GH}/releases/latest`;
const CACHE_KEY = "https://sequelbridge.internal/latest-dmg";
const TTL_SECONDS = 600;
const UA = { "user-agent": "sequelbridge-download" };

async function latestDmgUrl(ctx) {
  const cache = caches.default;
  const hit = await cache.match(CACHE_KEY);
  if (hit) return hit.text();

  const page = await fetch(FALLBACK, { redirect: "manual", headers: UA });
  const tag = (page.headers.get("location") || "").match(/\/releases\/tag\/(v?(\d[^/?#]*))$/);
  if (!tag) throw new Error(`no tag in redirect (status ${page.status})`);
  const url = `${GH}/releases/download/${tag[1]}/SequelBridge-${tag[2]}.dmg`;

  const probe = await fetch(url, { method: "HEAD", redirect: "manual", headers: UA });
  if (probe.status !== 302 && probe.status !== 200) throw new Error(`${tag[1]} has no SequelBridge-${tag[2]}.dmg (${probe.status})`);

  ctx.waitUntil(cache.put(CACHE_KEY, new Response(url, { headers: { "cache-control": `max-age=${TTL_SECONDS}` } })));
  return url;
}

export async function onRequestGet(ctx) {
  const headers = { "cache-control": "no-store" };
  try { headers.location = await latestDmgUrl(ctx); }
  catch (e) { console.error(e.message); headers.location = FALLBACK; headers["x-download-fallback"] = e.message; }
  return new Response(null, { status: 302, headers });
}
