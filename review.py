#!/usr/bin/env python3
r"""
snapsift / review.py  (visual review UI)
========================================

Eyeball every cluster before you delete anything. Opens a local web page that
shows each near-duplicate group side by side, with snapsift's proposed keeper
highlighted. Click a different frame to promote it; protected frames (favorites,
edited frames, and documents/scans) are locked and can never be deleted. When
you're happy, "Export" writes a delete-uuids.txt
that you feed straight to delete.applescript.

It reads the SAME groups.json that scan.py and hash.py emit, so it works for
both time-burst clusters and perceptual (L3) clusters.

Zero runtime dependencies (stdlib http.server). If Pillow is installed the
thumbnails are downscaled server-side for a snappier grid; otherwise the full
derivative JPEG is served and the browser scales it.

Usage:
    python3 review.py --groups groups.json \
                      --library ~/Pictures/Photos\ Library.photoslibrary
    # → open http://127.0.0.1:8765 , review, Export
    python3 review.py --groups hash-groups.json --uuid-out hash-delete-uuids.txt
"""

from __future__ import annotations
import argparse, io, json, re, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# Photos asset UUIDs are uppercase hex-and-dash, 36 chars. Everything that
# arrives over HTTP is validated against this before touching the filesystem
# or the export file — a stray "../" would otherwise reach Path.glob (which
# raises on "..") and the uuid list is later fed to delete tooling.
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\Z")

from pick import keeper, is_protected   # default keeper choice + protection guard
from hash import resolve_thumb          # locate a thumbnail for a uuid


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>snapsift · review</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
         background:#0b0b0d; color:#e8e8ea; }
  header { position:sticky; top:0; z-index:10; display:flex; align-items:center; gap:16px;
           padding:12px 18px; background:#151518; border-bottom:1px solid #26262b; }
  header h1 { font-size:15px; margin:0; font-weight:600; letter-spacing:.2px; }
  header .stat { color:#9a9aa2; }
  header .stat b { color:#e8e8ea; }
  .spacer { flex:1; }
  button { font:inherit; border:1px solid #3a3a42; background:#202028; color:#e8e8ea;
           padding:7px 14px; border-radius:8px; cursor:pointer; }
  button.primary { background:#2f7d4f; border-color:#2f7d4f; }
  button:hover { filter:brightness(1.12); }
  main { padding:16px 18px 80px; }
  .group { margin:0 0 22px; padding-bottom:16px; border-bottom:1px solid #1d1d22; }
  .group h2 { font-size:12px; font-weight:500; color:#8a8a92; margin:0 0 8px; }
  .row { display:flex; flex-wrap:wrap; gap:10px; }
  .card { width:150px; cursor:pointer; border:2px solid transparent; border-radius:10px;
          overflow:hidden; background:#161619; position:relative; transition:.1s; }
  .card img { width:100%; height:150px; object-fit:cover; display:block; background:#0d0d10; }
  .card .meta { padding:5px 7px; font-size:11px; color:#9a9aa2; white-space:nowrap;
                overflow:hidden; text-overflow:ellipsis; }
  .card.keep   { border-color:#36c172; }
  .card.delete img { opacity:.32; }
  .card.fav    { border-color:#d6a738; }
  .badge { position:absolute; top:6px; left:6px; font-size:10px; font-weight:700;
           padding:2px 6px; border-radius:6px; letter-spacing:.4px; }
  .keep   .badge.k { background:#36c172; color:#04110a; }
  .delete .badge.d { background:#e0524e; color:#1a0403; }
  .fav    .badge.f { background:#d6a738; color:#1a1203; right:6px; left:auto; }
  .hint { color:#74747c; font-size:12px; margin:2px 0 14px; }
  #toast { position:fixed; bottom:18px; left:50%; transform:translateX(-50%);
           background:#2f7d4f; color:#fff; padding:10px 18px; border-radius:10px;
           opacity:0; transition:.2s; pointer-events:none; }
  #toast.show { opacity:1; }
</style></head>
<body>
<header>
  <h1>snapsift · review</h1>
  <span class="stat"><b id="ngroups">0</b> groups</span>
  <span class="stat"><b id="ndelete">0</b> to delete</span>
  <span class="spacer"></span>
  <button id="export" class="primary">Export delete list →</button>
</header>
<p class="hint" style="padding:0 18px;">Click any frame to make it the keeper.
  ★ favorites are locked and never deleted. Red = will be deleted.</p>
<main id="main"></main>
<div id="toast"></div>
<script>
let GROUPS = [];
async function load() {
  GROUPS = await (await fetch('/api/groups')).json();
  document.getElementById('ngroups').textContent = GROUPS.length;
  render();
}
function render() {
  const main = document.getElementById('main');
  main.innerHTML = '';
  let ndel = 0;
  GROUPS.forEach((g, gi) => {
    const sec = document.createElement('div'); sec.className = 'group';
    const h = document.createElement('h2');
    h.textContent = `#${gi+1} · ${g.size} frames · spans ${g.span_sec}s`;
    sec.appendChild(h);
    const row = document.createElement('div'); row.className = 'row';
    g.photos.forEach((p, pi) => {
      const del = !p.is_keeper && !p.protected;
      if (del) ndel++;
      const card = document.createElement('div');
      card.className = 'card' + (p.is_keeper ? ' keep' : del ? ' delete' : '')
                              + (p.protected ? ' fav' : '');
      card.innerHTML =
        (p.is_keeper ? '<span class="badge k">KEEP</span>' : '') +
        (del ? '<span class="badge d">DELETE</span>' : '') +
        (p.favorite ? '<span class="badge f">★</span>' : '') +
        `<img loading="lazy" src="/thumb?uuid=${p.uuid}">`;
      // filename comes straight from Photos' ZORIGINALFILENAME and is
      // attacker-influenceable (AirDrop/Messages/downloads) — use textContent
      // so it can never be parsed as markup, unlike the innerHTML above.
      const meta = document.createElement('div'); meta.className = 'meta';
      meta.textContent = (p.filename || p.uuid.slice(0,8)) +
        (p.quality ? ' · q'+p.quality.toFixed(1) : '');
      card.appendChild(meta);
      card.onclick = () => { promote(gi, pi); };
      row.appendChild(card);
    });
    sec.appendChild(row);
    main.appendChild(sec);
  });
  document.getElementById('ndelete').textContent = ndel;
}
function promote(gi, pi) {
  const g = GROUPS[gi];
  if (g.photos[pi].protected) return;       // protected frames are always kept
  g.photos.forEach((p, i) => p.is_keeper = (i === pi));
  render();
}
async function exportList() {
  const deletes = [];
  GROUPS.forEach(g => g.photos.forEach(p => {
    if (!p.is_keeper && !p.protected) deletes.push(p.uuid);
  }));
  const r = await (await fetch('/api/export', {method:'POST',
    headers:{'content-type':'application/json'}, body:JSON.stringify({deletes})})).json();
  toast(`Wrote ${r.written} UUIDs → ${r.path}`);
}
function toast(msg) {
  const t = document.getElementById('toast'); t.textContent = msg; t.className = 'show';
  setTimeout(() => t.className = '', 2600);
}
document.getElementById('export').onclick = exportList;
load();
</script></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    # set by main()
    groups: list = []
    library: Path = None
    uuid_out: Path = None
    thumb_px: int = 400

    def log_message(self, *a):           # quiet console
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            return self._send(200, PAGE)
        if u.path == "/api/groups":
            return self._send(200, json.dumps(self.groups),
                              "application/json; charset=utf-8")
        if u.path == "/thumb":
            uuid = (parse_qs(u.query).get("uuid") or [""])[0]
            if not UUID_RE.fullmatch(uuid):
                return self._send(404, b"", "image/jpeg")
            return self._send_thumb(uuid)
        return self._send(404, "not found")

    def _send_thumb(self, uuid):
        path = resolve_thumb(self.library, uuid) if uuid else None
        if not path:
            return self._send(404, b"", "image/jpeg")
        data = path.read_bytes()
        try:                              # optional server-side downscale
            from PIL import Image
            with Image.open(io.BytesIO(data)) as im:
                im = im.convert("RGB")
                im.thumbnail((self.thumb_px, self.thumb_px), Image.BILINEAR)
                buf = io.BytesIO(); im.save(buf, "JPEG", quality=82)
                data = buf.getvalue()
        except Exception:
            pass                          # serve the raw derivative as-is
        return self._send(200, data, "image/jpeg")

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/api/export":
            return self._send(404, "not found")
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")
        # Fail-closed protection guard: a protected frame (favorite / edited /
        # document) must NEVER reach the delete list, even from a stale or
        # tampered client POST. We re-derive the protected set server-side from
        # the groups we loaded and strip any such uuid before writing.
        protected = {p["uuid"] for g in self.groups for p in g["photos"]
                     if p["protected"]}
        uuids = [x for x in payload.get("deletes", [])
                 if isinstance(x, str) and UUID_RE.fullmatch(x)
                 and x not in protected]
        self.uuid_out.write_text("\n".join(uuids) + ("\n" if uuids else ""))
        self._send(200, json.dumps({"written": len(uuids),
                                    "path": str(self.uuid_out)}),
                   "application/json; charset=utf-8")


def build_groups(groups_file: Path):
    """Read a groups.json (scan or hash) and annotate each photo's keeper flag."""
    data = json.loads(groups_file.read_text())
    out = []
    for g in data["groups"]:
        photos = g["photos"]
        keep = keeper(photos)
        out.append({
            "size":     g["size"],
            "span_sec": g.get("span_sec", 0),
            "photos": [{
                "uuid":      p["uuid"],
                "filename":  p.get("filename", ""),
                "uti":       p.get("uti", ""),
                "favorite":  bool(p.get("favorite")),
                # Protected = favorite OR edited OR document — never deletable,
                # the same single guard the Core and the app use. (edited /
                # is_document are absent on older groups.json → falsy → no-op.)
                "protected": is_protected(p),
                "quality":   p.get("quality") or 0.0,
                "taken_iso": p.get("taken_iso", ""),
                "is_keeper": p["uuid"] == keep["uuid"],
            } for p in photos],
        })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--groups", type=Path, default=Path("groups.json"),
                    help="groups.json from scan.py or hash.py")
    ap.add_argument("--library", type=Path,
                    default=Path.home() / "Pictures" / "Photos Library.photoslibrary")
    ap.add_argument("--uuid-out", type=Path, default=Path("delete-uuids.txt"),
                    help="Where Export writes the reviewed delete list")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--thumb-px", type=int, default=400,
                    help="Server-side thumbnail size (needs Pillow; ignored otherwise)")
    ap.add_argument("--no-open", action="store_true", help="Don't auto-open the browser")
    args = ap.parse_args()

    Handler.groups   = build_groups(args.groups)
    Handler.library  = args.library
    Handler.uuid_out = args.uuid_out
    Handler.thumb_px = args.thumb_px

    ndel = sum(1 for g in Handler.groups for p in g["photos"]
               if not p["is_keeper"] and not p["protected"])
    url = f"http://127.0.0.1:{args.port}"
    print(f"📷 snapsift review — {len(Handler.groups):,} groups, "
          f"{ndel:,} proposed deletions")
    print(f"   {url}   (Ctrl-C to stop)")
    if not args.no_open:
        webbrowser.open(url)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n👋 stopped")


if __name__ == "__main__":
    main()
