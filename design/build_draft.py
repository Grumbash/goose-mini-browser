#!/usr/bin/env python3
"""Builds goose-browser-draft.html, design draft 1 for the goose browser.

The page carries the repo review, the memory measurements (computed from the
raw JSON in measurements/), the research recipe, the proposed design and three
interface directions with Mac and iPhone mockups. The output is static HTML:
every word and mock is in the markup, and nothing needs JavaScript.

    python3 design/build_draft.py
"""

import html
import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "goose-browser-draft.html"
MEAS = HERE / "measurements"
REPO = HERE.parent


# ---------------------------------------------------------------- data

def load(name):
    return {r["label"]: r for r in json.loads((MEAS / name).read_text())}


RUN1, RUN2 = load("run1.json"), load("run2.json")
FOUR = json.loads((MEAS / "run3-four-tabs.json").read_text())


def total(label):
    """(low, high) total footprint in MB across the two comparison runs."""
    vals = sorted(r[label]["total_mb"] for r in (RUN1, RUN2))
    return vals[0], vals[1]


def renderers(run, label):
    names = ("com.apple.WebKit.WebContent", "Google Chrome Helper (Renderer)")
    return round(sum(p["mb"] for p in run[label]["processes"] if p["name"] in names), 1)


def shell_range():
    vals = [p["mb"] for r in (RUN1, RUN2) for x in r.values() for p in x["processes"]
            if p["name"] == "webview_probe"]
    vals += [p["mb"] for p in FOUR["processes"] if p["name"] == "webview_probe"]
    return min(vals), max(vals)


BLANK_WK, BLANK_CR = total("webkit-blank"), total("chrome-blank")
THREE_WK, THREE_CR = total("webkit-3tabs"), total("chrome-3tabs")
PAGES_WK = sorted(renderers(r, "webkit-3tabs") for r in (RUN1, RUN2))
PAGES_CR = sorted(renderers(r, "chrome-3tabs") for r in (RUN1, RUN2))
REST_WK = sorted(round(r["webkit-3tabs"]["total_mb"] - renderers(r, "webkit-3tabs"), 1) for r in (RUN1, RUN2))
REST_CR = sorted(round(r["chrome-3tabs"]["total_mb"] - renderers(r, "chrome-3tabs"), 1) for r in (RUN1, RUN2))
SPLIT_RUN2 = {
    "webkit": (renderers(RUN2, "webkit-3tabs"), round(RUN2["webkit-3tabs"]["total_mb"] - renderers(RUN2, "webkit-3tabs"), 1)),
    "chrome": (renderers(RUN2, "chrome-3tabs"), round(RUN2["chrome-3tabs"]["total_mb"] - renderers(RUN2, "chrome-3tabs"), 1)),
}
SHELL = shell_range()

# Per-tab weights for the mocks, from the four-tab run (one consistent run).
_tabs = {l.split()[1]: l.split()[2] for l in FOUR["log"] if l.startswith("TAB")}
_by_url = {_tabs[str(p["pid"])]: p["mb"] for p in FOUR["processes"] if str(p["pid"]) in _tabs}
W_WIKI = _by_url["https://en.wikipedia.org/wiki/Focaccia"]
W_MDN = _by_url["https://developer.mozilla.org/en-US/docs/Web/JavaScript"]
W_EXAMPLE = _by_url["https://example.com/"]
W_GITHUB = _by_url["https://github.com/aardappel/goose"]
W_BROWSER = round(sum(p["mb"] for p in FOUR["processes"] if p["name"] != "com.apple.WebKit.WebContent"), 1)
GITHUB_RANGE = (min(W_GITHUB, *[p["mb"] for r in (RUN1, RUN2) for p in r["webkit-3tabs"]["processes"] if p["mb"] > 150]),
                max(W_GITHUB, *[p["mb"] for r in (RUN1, RUN2) for p in r["webkit-3tabs"]["processes"] if p["mb"] > 150]))

# Illustrative values (no measurement exists): the local dev page and its phone view.
W_LOCAL, W_PHONEVIEW = 41.3, 37.8

LIVE_EVERYDAY = round(W_WIKI + W_MDN + W_EXAMPLE, 1)
WINDOW_EVERYDAY = round(LIVE_EVERYDAY + W_BROWSER, 1)
WINDOW_DEV = round(W_LOCAL + W_PHONEVIEW + W_MDN + W_BROWSER, 1)

GOOSE_LINES = sum(len(p.read_text().splitlines()) for p in (REPO / "browser").glob("*.goose"))
RUST_LINES = len((REPO / "goosenet/src/lib.rs").read_text().splitlines())


def mb(x):
    return f"{x:.1f}"


def rng(pair):
    lo, hi = pair
    return f"{lo:.1f}–{hi:.1f}"


def e(s):
    return html.escape(s, quote=True)


# ---------------------------------------------------------------- icons

SYMBOLS = {
    "chev-l": '<path d="m15 18-6-6 6-6"/>',
    "chev-r": '<path d="m9 18 6-6-6-6"/>',
    "reload": '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>',
    "lock": '<rect width="16" height="11" x="4" y="11" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    "share": '<path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><path d="m16 6-4-4-4 4"/><path d="M12 2v13"/>',
    "plus": '<path d="M5 12h14"/><path d="M12 5v14"/>',
    "side": '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/>',
    "code": '<path d="m16 18 6-6-6-6"/><path d="m8 6-6 6 6 6"/>',
    "phone": '<rect width="12" height="20" x="6" y="2" rx="2.5"/><path d="M11 18h2"/>',
    "dots": '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
    "tabs": '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2"/>',
    "globe": '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
    "book": '<path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/>',
    "arrow": '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
    "moon": '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
    "cols": '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M12 3v18"/>',
    "term": '<path d="m4 17 6-6-6-6"/><path d="M12 19h8"/>',
    "alert": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    "check": '<path d="M20 6 9 17l-5-5"/>',
    "laptop": '<path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16"/>',
    "wifi": '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.86a10 10 0 0 1 14 0"/><path d="M8.5 16.43a5 5 0 0 1 7 0"/>',
    "search": '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    # Brand marks from Simple Icons (CC0), filled.
    "gh": '<path fill="currentColor" stroke="none" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>',
    "mdn": '<path fill="currentColor" stroke="none" d="m21.538 1.1-6.745 21.8h-2.77L18.77 1.1ZM24 1.1v21.8h-2.462V1.1Zm-12 0v21.8H9.538V1.1Zm-2.462 0L2.77 22.9H0L6.746 1.1Z"/>',
    "wiki": '<path fill="currentColor" stroke="none" d="M12.09 13.119c-.936 1.932-2.217 4.548-2.853 5.728-.616 1.074-1.127.931-1.532.029-1.406-3.321-4.293-9.144-5.651-12.409-.251-.601-.441-.987-.619-1.139-.181-.15-.554-.24-1.122-.271C.103 5.033 0 4.982 0 4.898v-.455l.052-.045c.924-.005 5.401 0 5.401 0l.051.045v.434c0 .119-.075.176-.225.176l-.564.031c-.485.029-.727.164-.727.436 0 .135.053.33.166.601 1.082 2.646 4.818 10.521 4.818 10.521l.136.046 2.411-4.81-.482-1.067-1.658-3.264s-.318-.654-.428-.872c-.728-1.443-.712-1.518-1.447-1.617-.207-.023-.313-.05-.313-.149v-.468l.06-.045h4.292l.113.037v.451c0 .105-.076.15-.227.15l-.308.047c-.792.061-.661.381-.136 1.422l1.582 3.252 1.758-3.504c.293-.64.233-.801.111-.947-.07-.084-.305-.22-.812-.24l-.201-.021c-.052 0-.098-.015-.145-.051-.045-.031-.067-.076-.067-.129v-.427l.061-.045c1.247-.008 4.043 0 4.043 0l.059.045v.436c0 .121-.059.178-.193.178-.646.03-.782.095-1.023.439-.12.186-.375.589-.646 1.039l-2.301 4.273-.065.135 2.792 5.712.17.048 4.396-10.438c.154-.422.129-.722-.064-.895-.197-.172-.346-.273-.857-.295l-.42-.016c-.061 0-.105-.014-.152-.045-.043-.029-.072-.075-.072-.119v-.436l.059-.045h4.961l.041.045v.437c0 .119-.074.18-.209.18-.648.03-1.127.18-1.443.421-.314.255-.557.616-.736 1.067 0 0-4.043 9.258-5.426 12.339-.525 1.007-1.053.917-1.503-.031-.571-1.171-1.773-3.786-2.646-5.71l.053-.036z"/>',
}


def sprite():
    body = "".join(f'<symbol id="i-{k}" viewBox="0 0 24 24">{v}</symbol>' for k, v in SYMBOLS.items())
    return f'<svg class="sprite" aria-hidden="true">{body}</svg>'


def ic(name, cls=""):
    return f'<svg class="i {cls}" aria-hidden="true"><use href="#i-{name}"/></svg>'


# ---------------------------------------------------------------- mock content

EVERYDAY = dict(
    spaces=("Personal", "goose"), space="Personal",
    tabs=[
        dict(fav="wiki", title="Focaccia – Wikipedia", host="en.wikipedia.org", path="/wiki/Focaccia", mb=W_WIKI, live=True, on=True),
        dict(fav="mdn", title="JavaScript | MDN", host="developer.mozilla.org", mb=W_MDN, live=True),
        dict(fav="globe", title="Example Domain", host="example.com", mb=W_EXAMPLE, live=True),
        dict(fav="gh", title="aardappel/goose", host="github.com", mb=0.0, live=False, saves=W_GITHUB),
        dict(fav="globe", title="Weekend plan", host="example.net", mb=0.0, live=False),
    ],
)
DEV = dict(
    spaces=("Personal", "goose"), space="goose",
    tabs=[
        dict(fav="term", title="goose site · local", host="localhost:5173", path="/", mb=W_LOCAL, live=True, on=True),
        dict(fav="mdn", title="JavaScript | MDN", host="developer.mozilla.org", mb=W_MDN, live=True),
        dict(fav="gh", title="aardappel/goose", host="github.com", mb=0.0, live=False, saves=W_GITHUB),
        dict(fav="gh", title="Grumbash/goose-mini-browser", host="github.com", mb=0.0, live=False),
    ],
)

REQUESTS = [  # illustrative dev-server traffic
    ("18", "GET", "/", "html", "3.2 KB", 200),
    ("32", "GET", "/src/main.ts", "js", "41.6 KB", 200),
    ("21", "GET", "/src/hero.css", "css", "6.1 KB", 200),
    ("44", "GET", "/fonts/display.woff2", "font", "38.4 KB", 200),
    ("112", "GET", "/api/weights", "json", "0.4 KB", 500),
    ("27", "GET", "/img/phone.webp", "img", "88.0 KB", 200),
]


def clock(live):
    return f'<span class="clk {"live" if live else "sleep"}" aria-hidden="true"><i></i></span>'


def tab_row(d, t):
    cls = ["tab", "live" if t["live"] else "sleep"]
    if t.get("on"):
        cls.append("on")
    lead = clock(t["live"]) if d == "a" else ""
    if t["live"]:
        weight = f'<span class="w">{mb(t["mb"])}</span>'
    elif d == "c":
        weight = f'<span class="w zz">{ic("moon")}0.0</span>'
    elif d == "b":
        weight = '<span class="w zz">asleep</span>'
    else:
        weight = '<span class="w">0.0</span>'
    return (f'<li class="{" ".join(cls)}">{lead}<span class="fav">{ic(t["fav"])}</span>'
            f'<span class="t">{e(t["title"])}</span>{weight}</li>')


def side_foot(d, sc, extra=0.0, extra_label=""):
    live = [t for t in sc["tabs"] if t["live"]]
    asleep = [t for t in sc["tabs"] if not t["live"]]
    pages = round(sum(t["mb"] for t in live) + extra, 1)
    whole = round(pages + W_BROWSER, 1)
    if d == "a":
        rows = [
            (clock(True), f"Live {len(live)}" + (f" + {extra_label}" if extra_label else ""), mb(pages)),
            (clock(False), f"Asleep {len(asleep)}", "0.0"),
            ("", "Browser", mb(W_BROWSER)),
        ]
        body = "".join(f'<div class="tt-r">{c or "<span></span>"}<span>{l}</span><b>{v}</b></div>' for c, l, v in rows)
        return (f'<div class="foot tt">{body}<div class="tt-r tot"><span></span><span>Window</span>'
                f'<b>{mb(whole)} MB</b></div></div>')
    if d == "b":
        return (f'<div class="foot bfoot"><span>{len(live)} live · {len(asleep)} asleep</span>'
                f'<b>{mb(whole)} MB</b></div>')
    return ""  # direction C carries its totals in the pack, at the top


def pack(sc, extra=0.0, extra_label=""):
    """Direction C's signature: the pack, at one fixed scale (500 MB = full width)."""
    live = [t for t in sc["tabs"] if t["live"]]
    asleep = [t for t in sc["tabs"] if not t["live"]]
    whole = round(sum(t["mb"] for t in live) + extra + W_BROWSER, 1)
    saved = round(sum(t.get("saves", 0) for t in asleep), 1)
    segs = [(t["title"].split(" ")[0], t["mb"], "p") for t in live]
    if extra:
        segs.append((extra_label, extra, "p2"))
    segs.append(("Browser", W_BROWSER, "s"))
    bar = "".join(f'<i class="{k}" style="width:{v / 5:.2f}%" title="{e(n)} {mb(v)} MB"></i>' for n, v, k in segs)
    return (f'<div class="pack"><div class="pk-h"><span class="pk-l">Pack</span>'
            f'<span class="pk-n">{mb(whole)}<small> MB</small></span></div>'
            f'<div class="pk-bar" role="img" aria-label="Window weight {mb(whole)} MB of a 500 MB scale">{bar}</div>'
            f'<div class="pk-k"><span>{len(live)} live{(" + " + extra_label) if extra else ""}</span>'
            f'<span class="zz">{ic("moon")}{len(asleep)} asleep, saving {mb(saved)} MB</span></div></div>')


def sidebar(d, sc, extra=0.0, extra_label=""):
    spaces = "".join(f'<span class="space{" on" if s == sc["space"] else ""}">{s}</span>' for s in sc["spaces"])
    top = pack(sc, extra, extra_label) if d == "c" else ""
    rows = "".join(tab_row(d, t) for t in sc["tabs"])
    return (f'<div class="side"><div class="lights"><i></i><i></i><i></i></div>'
            f'<div class="spaces">{spaces}</div>{top}'
            f'<div class="label"><span>Tabs</span><span>MB</span></div>'
            f'<ul class="tabs">{rows}</ul>{side_foot(d, sc, extra, extra_label)}</div>')


def toolbar(d, host, path, kind, dev=False):
    if d == "b":
        moves = [("phone", "iPhone"), ("cols", "Views"), ("code", "Dev")]
        arrows = "".join(f'<span class="mv{" on" if dev and lbl == "Dev" else ""}"><span class="sq">{ic(i)}</span>{lbl}</span>'
                         for i, lbl in moves)
        return (f'<div class="bar band"><span class="btn">{ic("chev-l")}</span><span class="btn">{ic("chev-r")}</span>'
                f'<span class="pict">{ic(kind)}</span><span class="dest"><b>{e(host)}</b><small>{e(path)}</small></span>'
                f'<span class="moves">{arrows}</span></div>')
    lead = clock(True) if d == "a" else ""
    devbtn = (f'<span class="btn txt on">{ic("phone")}Open on iPhone</span><span class="btn on">{ic("code")}</span>'
              if dev else f'<span class="btn">{ic("code")}</span>')
    return (f'<div class="bar"><span class="btn">{ic("side")}</span><span class="btn">{ic("chev-l")}</span>'
            f'<span class="btn">{ic("chev-r")}</span><span class="addr">{lead}{ic("lock", "lk")}'
            f'<span class="host">{e(host)}</span><span class="path">{e(path)}</span></span>'
            f'<span class="btn">{ic("share")}</span>{devbtn}<span class="btn">{ic("plus")}</span></div>')


ARTICLE = """
<div class="art">
  <h4>Focaccia</h4>
  <p>Focaccia is a flat, oven-baked Italian bread. Bakers press dimples into the dough with their
  fingertips and pour on olive oil and salt before it goes in, often with rosemary.</p>
  <p>It sits close to pizza dough in style and is eaten on its own, beside a meal, or split for
  sandwiches.</p>
  <h5>Regional styles</h5>
  <p>Genoa's focaccia is thin and glossy with oil. In Puglia, potato goes into the dough. The
  version from Recco is two thin sheets with soft cheese between them.</p>
</div>"""


def dev_area(d):
    rows = []
    for ms, verb, path, kind, size, status in REQUESTS:
        bad = status >= 400
        st = (f'<span class="st bad">{ic("alert")}{status}</span>' if bad else f'<span class="st">{status}</span>')
        rows.append(f'<span class="ms">{ms} ms</span><span class="pth{" bad" if bad else ""}">{verb} {path}</span>'
                    f'<span class="knd">{kind}</span><span class="sz">{size}</span>{st}')
    return f"""
<div class="devarea">
  <div class="views">
    <div class="vp"><span class="cap">1280 × 800</span>
      <div class="site"><div class="logo">goose</div>
        <h4>Light on memory. Quick on Mac and iPhone.</h4>
        <p>A browser that shows what every tab weighs and puts idle tabs to sleep.</p>
        <span class="cta">Join the beta</span>
        <div class="widget"><span>{ic("alert")}Tab weights did not load</span><small>GET /api/weights · 500</small></div>
      </div>
    </div>
    <div class="vp vp-ph"><span class="cap">390 × 844</span>
      <div class="site sm"><div class="logo">goose</div>
        <h4 class="over">Light on memory.</h4>
        <span class="flag">412 px wide on a 390 px screen</span>
        <p>A browser that shows what every tab weighs.</p>
      </div>
    </div>
  </div>
  <div class="drawer">
    <div class="dtabs"><span class="dtab">Console <b class="n bad">1</b></span><span class="dtab on">Requests <b class="n">{len(REQUESTS)}</b></span>
      <span class="dtab">Frames</span><span class="dtab">Weights</span><span class="dsp"></span><span class="dtab ins">{ic("search")}Inspect</span></div>
    <div class="reqs">{"".join(rows)}</div>
  </div>
</div>"""


def mock_mac(d, dev=False):
    if dev:
        sc, host, path, kind = DEV, "localhost:5173", "/", "term"
        page = dev_area(d)
        side = sidebar(d, sc, W_PHONEVIEW, "phone view")
    else:
        sc, host, path, kind = EVERYDAY, "en.wikipedia.org", "/wiki/Focaccia", "book"
        page = f'<div class="page">{ARTICLE}</div>'
        side = sidebar(d, sc)
    label = ("Mac, dev mode: the goose space with its local server, phone and desktop views side by side"
             if dev else "Mac, everyday: reading in the Personal space, with GitHub asleep")
    return (f'<div class="mac" role="img" aria-label="{e(label)}"><div class="win">{side}'
            f'<div class="main{" dev" if dev else ""}">{toolbar(d, host, path, kind, dev)}{page}</div></div></div>')


def mock_phone(d):
    if d == "b":
        bar = (f'<div class="phbar band"><span class="pict">{ic("book")}</span>'
               f'<span class="dest"><b>en.wikipedia.org</b><small>{mb(W_WIKI)} MB</small></span>'
               f'<span class="sq n">5</span></div>')
    elif d == "c":
        bar = (f'<div class="phbar"><span class="pb">{ic("chev-l")}</span><span class="pill">'
               f'<span class="host">en.wikipedia.org</span></span>'
               f'<span class="pkm"><b>{mb(W_WIKI)}</b><i style="width:{W_WIKI / 5:.1f}%"></i></span>'
               f'<span class="pb">{ic("tabs")}</span></div>')
    else:
        bar = (f'<div class="phbar"><span class="pb">{ic("chev-l")}</span><span class="pill">{clock(True)}'
               f'<span class="host">en.wikipedia.org</span><b class="w">{mb(W_WIKI)}</b></span>'
               f'<span class="pb">{ic("tabs")}</span><span class="pb">{ic("dots")}</span></div>')
    sync = clock(True) if d == "a" else ic("laptop")
    status = ('<span class="sicons"><svg viewBox="0 0 18 12" class="sig" aria-hidden="true"><rect x="0" y="8" width="3" height="4" rx="1"/>'
              '<rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/>'
              '<rect x="15" y="0" width="3" height="12" rx="1"/></svg>' + ic("wifi", "wf") +
              '<svg viewBox="0 0 27 13" class="bat" aria-hidden="true"><rect x=".5" y=".5" width="23" height="12" rx="3.5"/>'
              '<rect x="2.5" y="2.5" width="17" height="8" rx="2" class="lvl"/><path d="M25.5 4.5v4a2.2 2.2 0 0 0 0-4Z" class="lvl"/></svg></span>')
    return (f'<div class="phone" role="img" aria-label="iPhone: the article continues from the Mac, and the Mac offers its local server">'
            f'<div class="ph"><div class="dev"><div class="island"></div><div class="status"><span>9:41</span>{status}</div>'
            f'<div class="handoff">{sync}<span>From your Mac</span><b>localhost:5173</b><span class="go">Open</span></div>'
            f'<div class="ph-art"><h4>Focaccia</h4>'
            f'<p>Focaccia is a flat, oven-baked Italian bread. Bakers press dimples into the dough with their fingertips '
            f'and pour on olive oil and salt before it goes in, often with rosemary.</p>'
            f'<p>It sits close to pizza dough in style and is eaten on its own, beside a meal, or split for sandwiches.</p>'
            f'<h5>Regional styles</h5><p>Genoa\'s focaccia is thin and glossy with oil.</p></div>'
            f'{bar}<div class="home"></div></div></div></div>')


# ---------------------------------------------------------------- directions

DIRECTIONS = [
    dict(
        key="a", letter="A", name="Station",
        thesis="The calm of a Swiss railway: white, black, and red only for what is running.",
        move=("Stop-to-go. Every live tab carries a small second hand that sweeps and waits at the top "
              "of the minute, the way Swiss station clocks wait for the signal. A sleeping tab's hand stands "
              "still and its weight drops to 0 MB. When Mac and iPhone sync, every hand moves together."),
        palette=[("Signal red", "#EB0000", "live tabs only"), ("Departure yellow", "#FFDE00", "selection"),
                 ("Sign blue", "#1D2A6E", "spaces"), ("Clock black", "#0F0F0F", "ink"),
                 ("Station white", "#FFFFFF", "ground")],
        type="San Francisco throughout, with tabular figures set in a timetable's column rhythm.",
        kept=[("Data field", "exact megabytes with one decimal, never “high” or “low”"),
              ("Orienteering map", "red belongs to the live tab and nothing else"),
              ("Botanical folio", "every weight drawn at one fixed scale"),
              ("Boarding pass", "rows move in place, and a tab that changed while hidden keeps its mark until you look"),
              ("Developer console", "dev panels fold away by priority, and destructive actions stand apart")],
        risk=("Restraint can tip into austere, and the red only works while it stays rare. The SBB clock face is a "
              "licensed design, so we borrow its stop-to-go timing, never the face or its disc hand."),
    ),
    dict(
        key="b", letter="B", name="Terminal",
        thesis="Airport wayfinding for the web: one yellow band says where you are and where you can go next.",
        move=("The sign band. The toolbar is a yellow band with a black pictogram square for the kind of page, the "
              "destination in large type, and the next moves (iPhone, views, dev) locked to its edge. The tab you "
              "follow stays yellow from the sidebar to the band; everything else is black and white."),
        palette=[("Signal yellow", "#FFCC00", "the band and the followed tab"), ("Sign black", "#0B0B0B", "panels"),
                 ("Panel frame", "#1A1A1A", "sidebar"), ("Surface grey", "#E6E6E6", "ground"),
                 ("Icon white", "#FFFFFF", "pictograms")],
        type="Signika for destinations and figures; San Francisco for controls.",
        kept=[],
        risk=("Yellow tires the eye if it spreads past the band and the followed tab. It is the boldest of the "
              "three for an everyday browser."),
    ),
    dict(
        key="c", letter="C", name="Pack",
        thesis="Built like ultralight gear: everything carries its weight, and the pack is always in view.",
        move=("The pack. The sidebar opens with the window's total and a bar split by tab at one fixed scale "
              "(500 MB across). Sleeping tabs leave the bar, turn glacier blue, and show what they save."),
        palette=[("Safety orange", "#FF5A1F", "live and primary"), ("Glacier blue", "#0796B8", "asleep"),
                 ("Trail black", "#101418", "ink"), ("Fabric white", "#F4F8F7", "translucent sidebar"),
                 ("Contour grey", "#C9D3D1", "wallpaper lines")],
        type="Archivo, semi-condensed, for labels; Martian Mono for weights; San Francisco for controls.",
        kept=[],
        risk=("It sits closest to Arc's and Zen's sidebar, so it can read as familiar. The outdoor world has to stay "
              "in colour, type and the pack bar, never in textures."),
        pick=True,
    ),
]


def direction_block(dd):
    k = dd["key"]
    chips = "".join(f'<li><span class="sw" style="background:{hx}"></span><span><b>{n}</b>'
                    f'<span class="hx">{hx} · {role}</span></span></li>' for n, hx, role in dd["palette"])
    kept = ""
    if dd["kept"]:
        kept = ('<div class="kept"><h4>Taken from the worlds we turned down</h4><ul>' +
                "".join(f"<li><b>{src}:</b> {txt}</li>" for src, txt in dd["kept"]) + "</ul></div>")
    pick = ('<p class="pick">My pick: it puts the product\'s promise, weight you can see, on every screen.</p>'
            if dd.get("pick") else "")
    return f"""
<article class="dirx dir-{k}" id="dir-{k}">
  <div class="dhead"><span class="dl">{dd["letter"]}</span><h3>{dd["name"]}</h3><p>{dd["thesis"]}</p></div>
  <div class="dgrid">
    <figure class="cell c-every"><div class="scroll">{mock_mac(k)}</div>
      <figcaption>Everyday: reading on the Mac. GitHub's {mb(W_GITHUB)} MB tab is asleep.</figcaption></figure>
    <figure class="cell c-phone">{mock_phone(k)}
      <figcaption>iPhone: the same browser, with the Mac's local server one tap away.</figcaption></figure>
    <figure class="cell c-dev"><div class="scroll">{mock_mac(k, dev=True)}</div>
      <figcaption>Dev mode: the project's phone and desktop views, requests and the failing call.</figcaption></figure>
    <div class="cell c-spec spec">
      <h4>Signature move</h4><p>{dd["move"]}</p>
      <h4>Palette</h4><ul class="chips">{chips}</ul>
      <h4>Type</h4><p>{dd["type"]}</p>
      <h4>Risk</h4><p>{dd["risk"]}</p>{pick}{kept}
    </div>
  </div>
</article>"""


# ---------------------------------------------------------------- styles

DOC_CSS = """
:root{
  /* Layout: one reading column for the argument, wide stages for evidence and mocks. */
  --bg:#f4f5f7; --surface:#ffffff; --surface-2:#eaedf2; --ink:#121419; --ink-2:#4a5161; --ink-3:#646b7b;
  --rule:#d9dde5; --accent:#2445f2; --on-accent:#ffffff;
  --crit:#c42f29; --high:#a65900; --med:#7a6300; --low:#5a6272; --ok:#0d7a51;
  --chart-a:#2445f2; --chart-b:#8d94a3;
  --f-display:"Familjen Grotesk", ui-sans-serif, system-ui, sans-serif;
  --f-body:"Atkinson Hyperlegible Next", ui-sans-serif, system-ui, sans-serif;
  --f-mono:"Spline Sans Mono", ui-monospace, "SF Mono", Menlo, monospace;
  --f-ui:-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", Roboto, sans-serif;
}
@media (prefers-color-scheme: dark){ :root:not([data-theme="light"]){
  --bg:#0d0f13; --surface:#15181e; --surface-2:#1d2129; --ink:#eceef3; --ink-2:#a8afbc; --ink-3:#8d95a3;
  --rule:#282d37; --accent:#8d9dff; --on-accent:#0d0f13;
  --crit:#ff6b62; --high:#f2a33a; --med:#e1c24a; --low:#a8afbc; --ok:#43c98d;
  --chart-a:#8d9dff; --chart-b:#5d6575; color-scheme:dark } }
:root[data-theme="dark"]{
  --bg:#0d0f13; --surface:#15181e; --surface-2:#1d2129; --ink:#eceef3; --ink-2:#a8afbc; --ink-3:#8d95a3;
  --rule:#282d37; --accent:#8d9dff; --on-accent:#0d0f13;
  --crit:#ff6b62; --high:#f2a33a; --med:#e1c24a; --low:#a8afbc; --ok:#43c98d;
  --chart-a:#8d9dff; --chart-b:#5d6575; color-scheme:dark }
html{ -webkit-text-size-adjust:100%; scroll-behavior:smooth }
body{ background:var(--bg); color:var(--ink); font:400 17px/1.62 var(--f-body); font-feature-settings:"kern" }
::selection{ background:color-mix(in srgb, var(--accent) 26%, transparent) }
a{ color:var(--accent); text-underline-offset:.2em; text-decoration-thickness:1px }
a:hover{ text-decoration-thickness:2px }
:focus-visible{ outline:2px solid var(--accent); outline-offset:3px; border-radius:4px }
.sprite{ position:absolute; width:0; height:0; overflow:hidden }
.i{ width:1em; height:1em; fill:none; stroke:currentColor; stroke-width:1.8; stroke-linecap:round; stroke-linejoin:round; flex:none }
.wrap{ max-width:1180px; margin:0 auto; padding-left:max(16px, env(safe-area-inset-left, 0px)); padding-right:max(16px, env(safe-area-inset-right, 0px)) }
section{ padding-block:96px 0 }
h1,h2,h3,h4{ font-family:var(--f-display); text-wrap:balance; margin:0; color:var(--ink) }
h1{ font-size:clamp(38px, 5.6vw, 66px); line-height:1.02; letter-spacing:-.03em; font-weight:700; max-width:15ch }
h2{ font-size:clamp(28px, 3.3vw, 38px); line-height:1.08; letter-spacing:-.02em; font-weight:650; margin-bottom:18px }
h3{ font-size:20px; line-height:1.25; letter-spacing:-.01em; font-weight:650 }
p{ margin:0 0 14px }
.prose{ max-width:68ch }
.lede{ font-size:clamp(18px, 2vw, 21px); line-height:1.5; color:var(--ink-2); max-width:60ch; margin-top:22px }
code{ font-family:var(--f-mono); font-size:.84em; background:var(--surface-2); padding:.1em .38em; border-radius:6px; overflow-wrap:anywhere }
.num{ font-variant-numeric:tabular-nums }

/* header */
.top{ padding-block:56px 0 }
.brandrow{ display:flex; flex-wrap:wrap; align-items:baseline; gap:10px 18px; margin-bottom:44px }
.word{ font:700 26px/1 var(--f-display); letter-spacing:-.04em }
.word small{ font:500 13px/1 var(--f-body); letter-spacing:0; color:var(--ink-3); margin-left:8px }
.meta{ color:var(--ink-3); font-size:15px }
.settled{ list-style:none; padding:0; margin:30px 0 0; display:flex; flex-wrap:wrap; gap:8px }
.settled li{ display:inline-flex; align-items:center; gap:8px; padding:8px 14px 8px 11px; border-radius:999px; background:var(--surface); box-shadow:0 1px 2px rgba(10,14,30,.06), 0 0 0 1px var(--rule); font-size:15px }
.settled li .i{ color:var(--ok); width:16px; height:16px }
.settled li.open{ background:transparent; box-shadow:inset 0 0 0 1.5px var(--rule); color:var(--ink-2) }
.settled li.open .i{ color:var(--ink-3) }
.toc{ display:flex; flex-wrap:wrap; gap:4px 22px; margin-top:34px; font-size:15px }
.toc a{ color:var(--ink-2); text-decoration:none } .toc a:hover{ color:var(--accent) }

/* review */
.facts{ display:flex; flex-wrap:wrap; gap:10px 28px; margin:22px 0 34px; padding:0; list-style:none; color:var(--ink-2); font-size:15.5px }
.facts b{ color:var(--ink); font-family:var(--f-display); font-size:22px; font-weight:650; margin-right:6px; font-variant-numeric:tabular-nums }
.findings{ list-style:none; margin:0; padding:0; display:grid; gap:26px }
.find{ display:grid; grid-template-columns:96px minmax(0,1fr); gap:6px 22px }
.sev{ align-self:start; justify-self:start; font:700 12px/1 var(--f-body); letter-spacing:.06em; text-transform:uppercase; padding:6px 9px; border-radius:6px; margin-top:3px; color:var(--surface); background:var(--low) }
.crit .sev{ background:var(--crit) } .high .sev{ background:var(--high) } .med .sev{ background:var(--med) }
.find h3{ margin-bottom:6px }
.find p{ color:var(--ink-2); margin:0 0 6px; max-width:72ch }
.ev{ font-size:14.5px; color:var(--ink-3) }
.tag{ display:inline-block; font:600 12px/1 var(--f-body); color:var(--ink); background:var(--surface-2); padding:4px 7px; border-radius:5px; margin-right:8px; vertical-align:1px }
.two{ display:grid; grid-template-columns:repeat(2, minmax(0,1fr)); gap:28px 56px; margin-top:52px }
.two ul{ margin:10px 0 0; padding-left:20px; color:var(--ink-2) } .two li{ margin-bottom:8px }
.note{ margin-top:30px; padding:16px 18px; background:var(--surface); border-radius:12px; box-shadow:0 0 0 1px var(--rule); color:var(--ink-2); max-width:78ch; font-size:16px }
.note b{ color:var(--ink) }

/* charts */
.chart{ margin:34px 0 0; background:var(--surface); border-radius:18px; padding:26px 26px 22px; box-shadow:0 1px 2px rgba(10,14,30,.05), 0 0 0 1px var(--rule) }
.chart h3{ font-size:17px; margin-bottom:16px }
.grp + .grp{ margin-top:20px }
.gl{ font-size:14.5px; color:var(--ink-3); margin-bottom:8px }
.row{ display:grid; grid-template-columns:120px minmax(0,1fr) 128px; align-items:center; gap:14px; min-height:30px }
.rl{ font-size:15px } .rv{ font:500 14px/1 var(--f-mono); text-align:right; font-variant-numeric:tabular-nums; color:var(--ink) }
.track{ position:relative; height:22px; background-image:linear-gradient(to right, var(--rule) 1px, transparent 1px); background-size:calc(200 / 650 * 100%) 100%; background-repeat:repeat-x }
.bar-min,.bar-rng{ position:absolute; top:3px; bottom:3px; border-radius:4px }
.bar-min{ left:0 } .bar-rng{ opacity:.38; border-radius:0 4px 4px 0 }
.a .bar-min,.a .bar-rng{ background:var(--chart-a) } .b .bar-min,.b .bar-rng{ background:var(--chart-b) }
.axis{ display:grid; grid-template-columns:120px minmax(0,1fr) 128px; gap:14px; margin-top:10px }
.ticks{ position:relative; height:16px; font:400 12px/1 var(--f-mono); color:var(--ink-3) }
.ticks span{ position:absolute; transform:translateX(-50%) } .ticks span:first-child{ transform:none }
.stack{ display:flex; height:30px; border-radius:6px; overflow:hidden }
.stack i{ display:block; height:100% }
.stack .pg{ background:var(--chart-a) } .stack .ov{ background:repeating-linear-gradient(135deg, var(--chart-a) 0 3px, color-mix(in srgb, var(--chart-a) 45%, transparent) 3px 7px) }
.b .stack .pg{ background:var(--chart-b) } .b .stack .ov{ background:repeating-linear-gradient(135deg, var(--chart-b) 0 3px, color-mix(in srgb, var(--chart-b) 45%, transparent) 3px 7px) }
.legend{ display:flex; flex-wrap:wrap; gap:6px 22px; font-size:14px; color:var(--ink-2); margin-top:8px }
.legend span{ display:inline-flex; align-items:center; gap:8px }
.legend i{ width:14px; height:14px; border-radius:3px; display:inline-block }
.chart figcaption{ margin-top:16px; font-size:14px; color:var(--ink-3) }
.reads{ display:grid; grid-template-columns:repeat(3, minmax(0,1fr)); gap:22px 36px; margin-top:34px }
.reads p{ margin:0; color:var(--ink-2) } .reads b{ display:block; color:var(--ink); font-family:var(--f-display); font-size:19px; line-height:1.25; margin-bottom:6px }
.so{ margin-top:30px; font:600 clamp(20px, 2.4vw, 25px)/1.3 var(--f-display); letter-spacing:-.01em; max-width:40ch }
.method{ margin-top:18px; font-size:14.5px; color:var(--ink-3); max-width:86ch }

/* recipe */
.recipe{ list-style:none; padding:0; margin:30px 0 0; display:grid; grid-template-columns:repeat(2, minmax(0,1fr)); gap:30px 48px }
.recipe h3{ margin-bottom:6px } .recipe p{ color:var(--ink-2); margin:0 }
.src-l{ font-size:14px; color:var(--ink-3); margin-top:6px !important }
.side-by{ display:grid; grid-template-columns:minmax(0,1.1fr) minmax(0,1fr); gap:28px; margin-top:52px; align-items:start }
.ios{ background:var(--ink); color:var(--bg); border-radius:18px; padding:26px 26px 22px }
.ios h3{ color:var(--bg); margin-bottom:10px } .ios p{ color:color-mix(in srgb, var(--bg) 80%, var(--ink)); margin-bottom:10px; font-size:16px }
.ios a{ color:inherit }
.ios .src-l{ color:color-mix(in srgb, var(--bg) 72%, var(--ink)) }
.when{ list-style:none; padding:0; margin:0; display:grid; gap:12px }
.when li{ display:grid; grid-template-columns:96px minmax(0,1fr); gap:14px; font-size:15.5px; color:var(--ink-2) }
.when time{ font:500 13.5px/1.6 var(--f-mono); color:var(--ink); font-variant-numeric:tabular-nums }
.engines{ width:100%; border-collapse:collapse; font-size:15px; margin-top:6px; min-width:620px }
.tablewrap{ overflow-x:auto; margin-top:34px }
.engines th,.engines td{ text-align:left; padding:11px 14px 11px 0; vertical-align:top; border-bottom:1px solid var(--rule) }
.engines th{ font-weight:600; color:var(--ink-3); font-size:13.5px }
.engines td:first-child{ font-weight:600; white-space:nowrap }
.engines tr.pick td{ color:var(--ink) } .engines td{ color:var(--ink-2) }
.yes{ color:var(--ok); font-weight:700 }

/* design */
.principles{ list-style:none; padding:0; margin:26px 0 0; display:grid; grid-template-columns:repeat(5, minmax(0,1fr)); gap:22px 30px }
@media (max-width: 1000px){ .principles{ grid-template-columns:repeat(2, minmax(0,1fr)) } .principles li:first-child{ grid-column:1 / -1 } }
@media (max-width: 560px){ .principles{ grid-template-columns:minmax(0,1fr) } }
.principles b{ display:block; font:650 18px/1.25 var(--f-display); margin-bottom:6px }
.principles p{ margin:0; color:var(--ink-2); font-size:16px }
.budget{ width:100%; border-collapse:collapse; font-size:15.5px; min-width:640px }
.budget th,.budget td{ text-align:left; vertical-align:top; padding:13px 18px 13px 0; border-bottom:1px solid var(--rule) }
.budget th{ font-size:13.5px; color:var(--ink-3); font-weight:600 }
.budget td:nth-child(2){ font-weight:600; color:var(--ink) } .budget td{ color:var(--ink-2) }
.flow{ list-style:none; padding:0; margin:30px 0 0; display:grid; grid-template-columns:repeat(4, minmax(0,1fr)); gap:14px }
.flow li{ background:var(--surface); border-radius:14px; padding:16px 16px 14px; box-shadow:0 0 0 1px var(--rule); position:relative }
.flow li + li::before{ content:""; position:absolute; left:-12px; top:26px; width:10px; height:2px; background:var(--ink-3) }
.flow b{ display:block; font:650 17px/1.2 var(--f-display); margin-bottom:6px }
.flow p{ margin:0; font-size:15px; color:var(--ink-2) } .flow .m{ display:block; margin-top:10px; font:500 13.5px/1.3 var(--f-mono); color:var(--ink) }
.arch{ display:grid; grid-template-columns:repeat(2, minmax(0,1fr)); gap:10px; margin-top:30px }
.arch div{ border-radius:14px; padding:15px 18px; background:var(--surface); box-shadow:0 0 0 1px var(--rule) }
.arch b{ display:block; font:650 16.5px/1.25 var(--f-display) } .arch span{ font-size:15px; color:var(--ink-2) }
.arch .full{ grid-column:1 / -1 }
.arch .os{ background:var(--ink); box-shadow:none } .arch .os b{ color:var(--bg) } .arch .os span{ color:color-mix(in srgb, var(--bg) 78%, var(--ink)) }
.arch .os code{ background:color-mix(in srgb, var(--bg) 16%, transparent); color:inherit }
.arch .later{ background:transparent; box-shadow:inset 0 0 0 1.5px var(--rule) }
.arch .core{ box-shadow:inset 0 0 0 1.5px var(--accent) }
.devmode{ margin-top:46px }
.devmode ul{ margin:12px 0 0; padding-left:20px; color:var(--ink-2); max-width:76ch } .devmode li{ margin-bottom:7px }

/* directions */
.dirs-intro{ max-width:72ch; color:var(--ink-2) }
.dirx{ margin-top:46px; border-radius:30px; padding:34px 34px 30px; background:var(--m-stage); color:var(--m-ink) }
.dhead{ display:grid; grid-template-columns:auto 1fr; gap:4px 16px; align-items:baseline; margin-bottom:26px }
.dhead .dl{ grid-row:span 2; font:700 54px/0.9 var(--f-display); color:var(--m-mark); letter-spacing:-.04em }
.dhead h3{ font-size:30px; color:var(--m-ink); letter-spacing:-.02em }
.dhead p{ margin:0; color:var(--m-ink2); font-size:18px; max-width:62ch }
.dgrid{ display:grid; grid-template-columns:minmax(0,1fr) 324px; grid-template-areas:"every phone" "dev spec"; gap:30px 34px; align-items:start }
.c-every{ grid-area:every } .c-phone{ grid-area:phone } .c-dev{ grid-area:dev } .c-spec{ grid-area:spec }
@media (max-width: 1240px){ .dgrid{ grid-template-columns:324px minmax(0,1fr); grid-template-areas:"every every" "dev dev" "phone spec" } }
.cell{ margin:0; min-width:0 }
.cell figcaption{ margin-top:12px; font-size:14.5px; color:var(--m-ink2) }
.scroll{ overflow-x:auto; padding:10px 16px 40px; margin:-10px -16px -32px }
.spec h4{ font:650 13px/1.2 var(--f-body); letter-spacing:.05em; text-transform:uppercase; color:var(--m-ink2); margin:0 0 6px }
.spec p{ font-size:15.5px; color:var(--m-ink); margin-bottom:18px }
.chips{ list-style:none; padding:0; margin:0 0 18px; display:grid; gap:7px }
.chips li{ display:grid; grid-template-columns:26px 1fr; gap:10px; align-items:center; font-size:14.5px }
.chips .sw{ width:26px; height:26px; border-radius:7px; box-shadow:inset 0 0 0 1px rgba(0,0,0,.14) }
.chips b{ display:block; font-weight:600 } .chips .hx{ display:block; font:400 12.5px/1.35 var(--f-mono); color:var(--m-ink2) }
.kept h4{ margin-top:4px } .kept ul{ margin:0; padding-left:18px; font-size:14.5px } .kept li{ margin-bottom:6px }
.pick{ font-weight:600 }
.declined{ margin-top:42px }
.declined ul{ list-style:none; padding:0; margin:14px 0 0; display:grid; grid-template-columns:repeat(auto-fit, minmax(260px, 1fr)); gap:16px 30px }
.declined b{ display:block; font:650 16px/1.3 var(--f-display) } .declined span{ font-size:15px; color:var(--ink-2) }

/* next */
.asks{ margin:22px 0 0; padding-left:22px; max-width:76ch } .asks li{ margin-bottom:12px; padding-left:4px } .asks b{ font-family:var(--f-display); font-weight:650 }
.order{ margin:14px 0 0; padding-left:22px; max-width:76ch; color:var(--ink-2) } .order li{ margin-bottom:8px }
.sources{ margin:12px 0 0; padding-left:22px; font-size:14.5px; color:var(--ink-3); columns:2 360px; column-gap:40px }
.sources li{ margin-bottom:6px; break-inside:avoid }
footer{ padding-block:80px 64px; color:var(--ink-3); font-size:14.5px }

@media (max-width: 980px){
  .reads{ grid-template-columns:minmax(0,1fr) }
  .flow{ grid-template-columns:repeat(2, minmax(0,1fr)) } .flow li:nth-child(3)::before{ display:none }
  .side-by{ grid-template-columns:minmax(0,1fr) }
}
@media (max-width: 720px){
  section{ padding-block:72px 0 }
  .find{ grid-template-columns:minmax(0,1fr) }
  .two,.recipe,.arch{ grid-template-columns:minmax(0,1fr) }
  .row{ grid-template-columns:minmax(0,1fr) auto; grid-template-areas:"l v" "t t"; gap:4px 10px; padding-bottom:8px }
  .row .rl{ grid-area:l } .row .rv{ grid-area:v } .row .track,.row .stack{ grid-area:t }
  .axis{ grid-template-columns:minmax(0,1fr) } .axis > span{ display:none }
  .dirx{ padding:24px 14px 20px; border-radius:22px }
  .dgrid{ grid-template-columns:minmax(0,1fr); grid-template-areas:"every" "phone" "dev" "spec" }
  .mac{ min-width:0 }
  .scroll{ overflow:visible; padding:0; margin:0 }
  .flow{ grid-template-columns:minmax(0,1fr) } .flow li::before{ display:none }
  .when li{ grid-template-columns:minmax(0,1fr); gap:2px }
  .phone{ margin-inline:auto }
}
"""

MOCK_CSS = """
/* ---- mocks: sizes are design pixels, scaled with the mock's own width ---- */
.mac{ container-type:inline-size; width:100%; min-width:680px }
.win{ position:relative; width:@d(1000); height:@d(640); border-radius:@d(12); overflow:hidden; display:grid;
  grid-template-columns:@d(250) minmax(0,1fr); background:var(--m-win); color:var(--m-ink); font-family:var(--f-ui);
  box-shadow:0 @d(28) @d(60) var(--m-shadow), 0 @d(3) @d(10) var(--m-shadow2), 0 0 0 @d(1) var(--m-edge); -webkit-font-smoothing:antialiased }
.side{ background:var(--m-side); color:var(--m-side-ink); display:flex; flex-direction:column; gap:@d(12);
  padding:@d(16) @d(12) @d(14); min-width:0; box-shadow:inset @d(-1) 0 0 var(--m-side-rule) }
.lights{ display:flex; gap:@d(8); padding-left:@d(6); height:@d(14); align-items:center }
.lights i{ width:@d(12); height:@d(12); border-radius:50%; background:#ff5f57; box-shadow:inset 0 0 0 @d(.5) rgba(0,0,0,.14) }
.lights i:nth-child(2){ background:#febc2e } .lights i:nth-child(3){ background:#28c840 }
.spaces{ display:flex; gap:@d(6); padding-left:@d(2) }
.space{ font-size:@d(12); font-weight:600; line-height:1; padding:@d(7) @d(11); border-radius:var(--m-r-pill); color:var(--m-side-ink2) }
.space.on{ background:var(--m-space); color:var(--m-space-ink) }
.label{ display:flex; justify-content:space-between; padding:0 @d(10) 0 @d(8); font-size:@d(11); font-weight:600; color:var(--m-side-ink2); margin-bottom:@d(-6) }
.tabs{ list-style:none; margin:0; padding:0; display:flex; flex-direction:column; gap:@d(2) }
.tab{ display:grid; grid-template-columns:@d(16) minmax(0,1fr) auto; align-items:center; column-gap:@d(8); height:@d(32);
  padding:0 @d(10) 0 @d(8); border-radius:var(--m-r); font-size:@d(13); color:var(--m-side-ink) }
.tab .fav{ display:grid; place-items:center; width:@d(16); height:@d(16); color:var(--m-fav) }
.tab .fav .i{ width:@d(15); height:@d(15) }
.tab .t{ overflow:hidden; white-space:nowrap; text-overflow:ellipsis }
.tab .w{ font-family:var(--m-num); font-variant-numeric:tabular-nums; font-size:@d(12); color:var(--m-side-ink2); display:inline-flex; align-items:center; gap:@d(4) }
.tab .w .i{ width:@d(11); height:@d(11) }
.tab.sleep .t,.tab.sleep .fav{ color:var(--m-side-ink2) }
.tab.on{ background:var(--m-sel); color:var(--m-sel-ink) } .tab.on .w,.tab.on .fav{ color:var(--m-sel-ink) }
.foot{ margin-top:auto }
.main{ display:grid; grid-template-rows:@d(52) minmax(0,1fr); min-width:0; min-height:0; background:var(--m-win) }
.bar{ display:flex; align-items:center; gap:@d(6); padding:0 @d(12) 0 @d(10); background:var(--m-bar); box-shadow:inset 0 @d(-1) 0 var(--m-rule); color:var(--m-ink2) }
.btn{ height:@d(28); min-width:@d(28); display:inline-flex; align-items:center; justify-content:center; gap:@d(6); border-radius:@d(7); flex:none; font-size:@d(12); font-weight:600 }
.btn .i{ width:@d(16); height:@d(16) }
.btn.txt{ padding:0 @d(10) }
.btn.on{ background:var(--m-ink); color:var(--m-win) }
.addr{ flex:1; min-width:0; height:@d(32); border-radius:@d(9); background:var(--m-field); display:flex; align-items:center; gap:@d(7); padding:0 @d(12); font-size:@d(13); color:var(--m-ink); margin:0 @d(4) }
.addr .lk{ width:@d(12); height:@d(12); color:var(--m-ink2) }
.addr .host{ font-weight:600; white-space:nowrap } .addr .path{ color:var(--m-ink2); overflow:hidden; white-space:nowrap; text-overflow:ellipsis }
.page{ overflow:hidden; background:var(--m-page); color:var(--m-page-ink); min-height:0 }
.art{ max-width:@d(560); margin:0 auto; padding:@d(46) @d(24); font-family:ui-serif, "New York", Georgia, serif }
.art .src,.ph-art .src{ font:500 @d(11)/1 var(--f-ui); color:var(--m-page-ink2); margin-bottom:@d(14) }
.art h4{ font:600 @d(38)/1.05 ui-serif, "New York", Georgia, serif; letter-spacing:-.015em; margin:0 0 @d(16); color:var(--m-page-ink) }
.art p{ font-size:@d(15.5); line-height:1.62; margin:0 0 @d(12) }
.art h5{ font:600 @d(19)/1.2 ui-serif, "New York", Georgia, serif; margin:@d(20) 0 @d(8) }

/* dev mode */
.devarea{ display:grid; grid-template-rows:minmax(0,1fr) @d(206); min-height:0; background:var(--m-devbg) }
.views{ display:grid; grid-template-columns:minmax(0,1fr) @d(196); gap:@d(14); padding:@d(14) @d(14) @d(12); min-height:0 }
.vp{ position:relative; background:var(--m-page); color:var(--m-page-ink); border-radius:@d(8); overflow:hidden; box-shadow:0 0 0 @d(1) var(--m-rule), 0 @d(6) @d(16) var(--m-shadow2); min-height:0 }
.vp-ph{ border-radius:@d(20) }
.vp .cap{ position:absolute; right:@d(10); top:@d(9); font:500 @d(10)/1 var(--m-num); font-variant-numeric:tabular-nums; color:var(--m-page-ink2) }
.site{ padding:@d(24) @d(26); font-family:var(--f-ui) }
.site .logo{ font:800 @d(14)/1 var(--f-ui); letter-spacing:-.03em }
.site h4{ font:750 @d(30)/1.02 var(--f-ui); letter-spacing:-.035em; margin:@d(22) 0 @d(10); max-width:@d(420); color:var(--m-page-ink) }
.site p{ font-size:@d(12.5); line-height:1.5; color:var(--m-page-ink2); max-width:@d(330); margin:0 }
.site .cta{ display:inline-block; margin-top:@d(14); padding:@d(8) @d(14); border-radius:@d(8); background:var(--m-page-ink); color:var(--m-page); font-weight:650; font-size:@d(12) }
.widget{ margin-top:@d(16); display:grid; gap:@d(3); padding:@d(10) @d(12); border-radius:@d(8); background:var(--m-field); font-size:@d(12); max-width:@d(330) }
.widget span{ display:inline-flex; align-items:center; gap:@d(6); font-weight:600 } .widget .i{ width:@d(13); height:@d(13); color:var(--m-err) }
.widget small{ font:400 @d(11)/1.3 var(--m-num); color:var(--m-page-ink2) }
.site.sm{ padding:@d(30) @d(14) @d(14) }
.site.sm h4{ font-size:@d(27); white-space:nowrap; margin:@d(18) 0 @d(6); width:max-content; outline:@d(1.5) dashed var(--m-err); outline-offset:@d(3) }
.site.sm p{ font-size:@d(11.5) }
.flag{ display:inline-block; font:600 @d(10)/1.2 var(--f-ui); color:var(--m-err); margin:@d(4) 0 @d(10) }
.drawer{ display:grid; grid-template-rows:@d(36) minmax(0,1fr); min-height:0; background:var(--m-win); box-shadow:inset 0 @d(1) 0 var(--m-rule); font-family:var(--f-ui) }
.dtabs{ display:flex; align-items:center; gap:@d(4); padding:0 @d(10) }
.dtab{ display:inline-flex; align-items:center; gap:@d(6); font-size:@d(12); font-weight:550; padding:@d(5) @d(10); border-radius:@d(6); color:var(--m-ink2) }
.dtab.on{ background:var(--m-field); color:var(--m-ink); font-weight:650 }
.dtab .n{ font:600 @d(10.5)/1 var(--m-num); padding:@d(3) @d(5); border-radius:@d(4); background:var(--m-field); color:var(--m-ink) }
.dtab .n.bad{ background:var(--m-err); color:var(--m-win) }
.dtab .i{ width:@d(13); height:@d(13) }
.dsp{ flex:1 }
.reqs{ display:grid; grid-template-columns:@d(64) minmax(0,1fr) @d(46) @d(72) @d(72); align-content:start; padding:@d(2) @d(14); font-size:@d(12); overflow:hidden }
.reqs > span{ padding:@d(5) @d(6) @d(5) 0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; box-shadow:inset 0 @d(-1) 0 var(--m-rule2); display:flex; align-items:center }
.reqs .ms,.reqs .sz,.reqs .st{ font-family:var(--m-num); font-variant-numeric:tabular-nums; justify-content:flex-end }
.reqs .ms{ color:var(--m-ink2); justify-content:flex-start }
.reqs .knd{ color:var(--m-ink2) }
.reqs .pth.bad{ font-weight:650 }
.reqs .st .i{ width:@d(12); height:@d(12); margin-right:@d(4) }
.reqs .st.bad{ color:var(--m-err); font-weight:700 }

/* clock (direction A) */
.clk{ position:relative; display:inline-block; width:@d(13); height:@d(13); border-radius:50%; box-shadow:inset 0 0 0 @d(1.3) var(--m-clockrim); background:var(--m-clockface); flex:none }
.clk i{ position:absolute; left:50%; bottom:50%; width:@d(1.6); height:42%; margin-left:@d(-.8); border-radius:@d(1); background:var(--m-live); transform-origin:50% 100% }
.clk.sleep i{ background:var(--m-sleep) }
.clk.live i{ animation:stopgo 60s linear infinite }
@keyframes stopgo{ 0%{ transform:rotate(0deg) } 97.5%{ transform:rotate(360deg) } 100%{ transform:rotate(360deg) } }

/* phone */
.phone{ width:300px; max-width:100%; padding:12px }
.ph{ container-type:inline-size }
.phone .dev{ position:relative; width:@p(390); height:@p(844); border-radius:@p(54); overflow:hidden;
  background:var(--m-page); color:var(--m-page-ink); font-family:var(--f-ui); -webkit-font-smoothing:antialiased;
  box-shadow:0 0 0 @p(9) var(--m-bezel), 0 0 0 @p(10.5) var(--m-bezel-edge), 0 @p(30) @p(50) var(--m-shadow) }
.phone .clk{ box-shadow:inset 0 0 0 @p(1.6) var(--m-clockrim) }
.island{ position:absolute; top:@p(11); left:50%; width:@p(122); height:@p(35); margin-left:@p(-61); border-radius:@p(18); background:#000; z-index:2 }
.status{ height:@p(54); display:flex; align-items:center; justify-content:space-between; padding:@p(4) @p(30) 0 @p(48); font:650 @p(16)/1 var(--f-ui) }
.sicons{ display:flex; align-items:center; gap:@p(6) } .sicons svg{ fill:currentColor }
.sig{ width:@p(18); height:@p(12) } .sicons .wf{ width:@p(17); height:@p(17); fill:none }
.bat{ width:@p(27); height:@p(13) } .bat rect:first-child{ fill:none; stroke:currentColor; opacity:.45 } .bat .lvl{ fill:currentColor }
.handoff{ display:flex; align-items:center; gap:@p(8); margin:@p(6) @p(14) 0; padding:@p(10) @p(12); border-radius:@p(16); background:var(--m-chip); font-size:@p(13.5); color:var(--m-page-ink) }
.handoff .i{ width:@p(17); height:@p(17); color:var(--m-page-ink2) }
.handoff b{ font-weight:650; white-space:nowrap; overflow:hidden; text-overflow:ellipsis } .handoff span{ white-space:nowrap }
.handoff .go{ margin-left:auto; font-weight:650; color:var(--m-link) }
.handoff .clk{ width:@p(15); height:@p(15) } .handoff .clk i{ width:@p(1.8); margin-left:@p(-.9) }
.ph-art{ padding:@p(20) @p(22); font-family:ui-serif, "New York", Georgia, serif }
.ph-art .src{ font-size:@p(12); margin-bottom:@p(12) }
.ph-art h4{ font:600 @p(34)/1.05 ui-serif, "New York", Georgia, serif; margin:0 0 @p(12); color:var(--m-page-ink) }
.ph-art p{ font-size:@p(17); line-height:1.55; margin:0 0 @p(12) }
.ph-art h5{ font:600 @p(21)/1.2 ui-serif, "New York", Georgia, serif; margin:@p(16) 0 @p(8) }
.phbar{ position:absolute; left:@p(14); right:@p(14); bottom:@p(28); height:@p(56); border-radius:@p(28); display:flex; align-items:center; gap:@p(4); padding:0 @p(8);
  background:var(--m-phbar); color:var(--m-ink); -webkit-backdrop-filter:blur(@p(18)) saturate(1.6); backdrop-filter:blur(@p(18)) saturate(1.6);
  box-shadow:0 @p(8) @p(24) var(--m-shadow2), 0 0 0 @p(1) var(--m-edge); z-index:3 }
.pb{ width:@p(40); height:@p(40); display:grid; place-items:center; flex:none } .pb .i{ width:@p(21); height:@p(21) }
.pill{ flex:1; min-width:0; height:@p(40); border-radius:@p(20); background:var(--m-field); display:flex; align-items:center; justify-content:center; gap:@p(7); padding:0 @p(12); font-size:@p(15) }
.pill .host{ font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
.pill .w{ font:600 @p(12)/1 var(--m-num); font-variant-numeric:tabular-nums; color:var(--m-ink2) }
.pill .clk{ width:@p(15); height:@p(15) } .pill .clk i{ width:@p(1.8); margin-left:@p(-.9) }
.home{ position:absolute; bottom:@p(8); left:50%; width:@p(134); height:@p(5); margin-left:@p(-67); border-radius:@p(3); background:var(--m-page-ink); opacity:.8; z-index:3 }

@media (prefers-reduced-motion: reduce){ .clk.live i{ animation:none; transform:rotate(132deg) } }
"""

DIR_CSS = {
    "a": ("""
  --m-stage:#e7e7e4; --m-mark:#eb0000; --m-ink:#0f0f0f; --m-ink2:#565654;
  --m-win:#ffffff; --m-side:#f4f4f2; --m-side-ink:#141414; --m-side-ink2:#6b6b68; --m-side-rule:#e2e2df;
  --m-bar:#ffffff; --m-field:#efefec; --m-rule:#e4e4e1; --m-rule2:#efefec; --m-edge:rgba(0,0,0,.10);
  --m-shadow:rgba(20,20,18,.20); --m-shadow2:rgba(20,20,18,.08);
  --m-live:#eb0000; --m-sleep:#a3a3a0; --m-clockface:#ffffff; --m-clockrim:#141414;
  --m-sel:#ffde00; --m-sel-ink:#111111; --m-space:#1d2a6e; --m-space-ink:#ffffff; --m-fav:#141414;
  --m-page:#ffffff; --m-page-ink:#191919; --m-page-ink2:#686866; --m-devbg:#f1f1ef; --m-err:#111111;
  --m-chip:#f1f1ef; --m-link:#1d2a6e; --m-phbar:rgba(255,255,255,.86); --m-bezel:#0f0f0f; --m-bezel-edge:#3a3a3a;
  --m-r:4px; --m-r-pill:4px; --m-num:var(--f-ui);""", """
  --m-stage:#0a0a0a; --m-mark:#ff3030; --m-ink:#f2f2f0; --m-ink2:#a5a5a2;
  --m-win:#141414; --m-side:#0d0d0d; --m-side-ink:#efefed; --m-side-ink2:#8f8f8c; --m-side-rule:#232323;
  --m-bar:#141414; --m-field:#222221; --m-rule:#262626; --m-rule2:#1d1d1d; --m-edge:rgba(255,255,255,.10);
  --m-shadow:rgba(0,0,0,.6); --m-shadow2:rgba(0,0,0,.35);
  --m-live:#ff3030; --m-sleep:#5e5e5c; --m-clockface:#141414; --m-clockrim:#e9e9e7;
  --m-sel:#ffde00; --m-sel-ink:#111111; --m-space:#2c3c9e; --m-space-ink:#ffffff; --m-fav:#efefed;
  --m-page:#171717; --m-page-ink:#ececea; --m-page-ink2:#9a9a97; --m-devbg:#0f0f0f; --m-err:#f2f2f0;
  --m-chip:#232322; --m-link:#8fa2ff; --m-phbar:rgba(30,30,30,.86); --m-bezel:#000000; --m-bezel-edge:#3a3a3a;"""),
    "b": ("""
  --m-stage:#e6e6e6; --m-mark:#0b0b0b; --m-ink:#0b0b0b; --m-ink2:#4f4f4f;
  --m-win:#ffffff; --m-side:#1a1a1a; --m-side-ink:#ffffff; --m-side-ink2:#9c9c9c; --m-side-rule:#000000;
  --m-bar:#ffcc00; --m-band:#ffcc00; --m-band-ink:#0b0b0b; --m-field:#f0f0f0; --m-rule:#e2e2e2; --m-rule2:#eeeeee; --m-edge:rgba(0,0,0,.14);
  --m-shadow:rgba(0,0,0,.22); --m-shadow2:rgba(0,0,0,.09);
  --m-live:#ffcc00; --m-sleep:#6f6f6f; --m-sel:#ffcc00; --m-sel-ink:#0b0b0b; --m-space:#ffcc00; --m-space-ink:#0b0b0b; --m-fav:#ffffff;
  --m-page:#ffffff; --m-page-ink:#141414; --m-page-ink2:#666666; --m-devbg:#f2f2f2; --m-err:#d81e05;
  --m-chip:#f2f2f2; --m-link:#0b0b0b; --m-phbar:#ffcc00; --m-bezel:#0b0b0b; --m-bezel-edge:#333333;
  --m-r:3px; --m-r-pill:3px; --m-num:"Signika", var(--f-ui);""", """
  --m-stage:#050505; --m-mark:#ffcc00; --m-ink:#f5f5f5; --m-ink2:#acacac;
  --m-win:#0f0f0f; --m-side:#000000; --m-side-ink:#ffffff; --m-side-ink2:#8a8a8a; --m-side-rule:#1f1f1f;
  --m-bar:#ffcc00; --m-band:#ffcc00; --m-band-ink:#0b0b0b; --m-field:#1d1d1d; --m-rule:#262626; --m-rule2:#1a1a1a; --m-edge:rgba(255,255,255,.12);
  --m-shadow:rgba(0,0,0,.6); --m-shadow2:rgba(0,0,0,.35);
  --m-page:#151515; --m-page-ink:#ececec; --m-page-ink2:#9d9d9d; --m-devbg:#0a0a0a; --m-err:#ff5a45;
  --m-chip:#1f1f1f; --m-link:#ffcc00; --m-bezel:#000000; --m-bezel-edge:#3a3a3a;"""),
    "c": ("""
  --m-stage:#e9f0ee; --m-mark:#ff5a1f; --m-ink:#101418; --m-ink2:#4f5b64;
  --m-win:#fbfcfc; --m-side:rgba(242,247,246,.58); --m-side-ink:#101418; --m-side-ink2:#5d6870; --m-side-rule:rgba(16,20,24,.08);
  --m-bar:#fbfcfc; --m-field:rgba(16,20,24,.055); --m-rule:rgba(16,20,24,.09); --m-rule2:rgba(16,20,24,.05); --m-edge:rgba(16,20,24,.12);
  --m-shadow:rgba(13,40,44,.24); --m-shadow2:rgba(13,40,44,.09);
  --m-live:#ff5a1f; --m-sleep:#0796b8; --m-sel:rgba(255,90,31,.14); --m-sel-ink:#101418; --m-space:#101418; --m-space-ink:#ffffff; --m-fav:#101418;
  --m-page:#ffffff; --m-page-ink:#14181c; --m-page-ink2:#64707a; --m-devbg:#f1f5f4; --m-err:#d92d20;
  --m-chip:rgba(16,20,24,.055); --m-link:#e2480f; --m-phbar:rgba(250,252,252,.72); --m-bezel:#101418; --m-bezel-edge:#3c4650;
  --m-r:8px; --m-r-pill:999px; --m-num:"Martian Mono", var(--f-mono);""", """
  --m-stage:#0b1113; --m-mark:#ff6a33; --m-ink:#eef3f3; --m-ink2:#9babb1;
  --m-win:#13181b; --m-side:rgba(20,28,31,.6); --m-side-ink:#eef3f3; --m-side-ink2:#91a0a6; --m-side-rule:rgba(255,255,255,.07);
  --m-bar:#13181b; --m-field:rgba(255,255,255,.07); --m-rule:rgba(255,255,255,.08); --m-rule2:rgba(255,255,255,.05); --m-edge:rgba(255,255,255,.12);
  --m-shadow:rgba(0,0,0,.6); --m-shadow2:rgba(0,0,0,.35);
  --m-live:#ff6a33; --m-sleep:#2cc5e6; --m-sel:rgba(255,106,51,.18); --m-sel-ink:#ffffff; --m-space:#eef3f3; --m-space-ink:#101418; --m-fav:#eef3f3;
  --m-page:#121719; --m-page-ink:#e6ebec; --m-page-ink2:#93a1a7; --m-devbg:#0e1315; --m-err:#ff6b5e;
  --m-chip:rgba(255,255,255,.07); --m-link:#ff8a5c; --m-phbar:rgba(24,32,35,.72); --m-bezel:#000000; --m-bezel-edge:#3c4650;"""),
}

CONTOURS = ("M-40 120C80 60 190 110 300 70S520 10 640 80 860 150 1040 90"
            "M-40 200C90 140 210 190 320 150S540 90 660 160 880 230 1040 170"
            "M-40 280C100 220 230 270 340 230S560 170 680 240 900 310 1040 250"
            "M-40 470C120 420 250 470 380 430S600 380 720 440 920 500 1040 450"
            "M-40 550C130 500 260 560 390 520S610 460 740 530 930 590 1040 540"
            "M560 300c60-40 150-30 170 20s-40 90-110 80-120-60-60-100Z"
            "M590 310c40-20 100-15 110 15s-30 55-75 50-75-40-35-65Z")


def wall(stroke):
    svg = (f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 640' preserveAspectRatio='xMidYMid slice'>"
           f"<path d='{CONTOURS}' fill='none' stroke='{stroke}' stroke-width='1.6'/></svg>")
    return "url(\"data:image/svg+xml," + svg.replace("#", "%23").replace('"', "'") + "\")"


def direction_css():
    out = []
    for k, (light, dark) in DIR_CSS.items():
        out.append(f".dir-{k}{{{light}}}")
        out.append(f"@media (prefers-color-scheme: dark){{ :root:not([data-theme=\"light\"]) .dir-{k}{{{dark}}} }}")
        out.append(f":root[data-theme=\"dark\"] .dir-{k}{{{dark}}}")
    out.append(f".dir-c{{ --m-wall:{wall('#b7c9c5')} }}")
    out.append(f"@media (prefers-color-scheme: dark){{ :root:not([data-theme=\"light\"]) .dir-c{{ --m-wall:{wall('#22363a')} }} }}")
    out.append(f":root[data-theme=\"dark\"] .dir-c{{ --m-wall:{wall('#22363a')} }}")
    # C's stage is a contour-line wallpaper, so its translucent sidebar has something to blur.
    out.append(".dir-c{ background:var(--m-wall) center top / 1400px 896px no-repeat, var(--m-stage) }")
    return "\n".join(out)


SIGNATURE_CSS = """
/* A: every tab row leads with its clock */
.dir-a .tab{ grid-template-columns:@d(13) @d(16) minmax(0,1fr) auto }
/* A: timetable footer */
.dir-a .tt{ display:grid; gap:@d(2); padding:@d(10) @d(8) 0; box-shadow:inset 0 @d(1) 0 var(--m-side-rule) }
.dir-a .tt-r{ display:grid; grid-template-columns:@d(13) minmax(0,1fr) auto; gap:@d(8); align-items:center; font-size:@d(12); color:var(--m-side-ink2); height:@d(22) }
.dir-a .tt-r b{ font-weight:600; color:var(--m-side-ink); font-variant-numeric:tabular-nums }
.dir-a .tt-r.tot{ color:var(--m-side-ink); font-weight:650; margin-top:@d(4) } .dir-a .tt-r.tot b{ font-weight:750 }
.dir-a .addr .clk{ margin-right:@d(2) }
.dir-a .space{ font-weight:700 }

/* B: the sign band */
.dir-b .side{ box-shadow:none }
.dir-b .tab{ font-weight:500 } .dir-b .tab.on{ font-weight:700 }
.dir-b .tab .w.zz{ font:600 @d(10)/1 var(--f-ui); letter-spacing:.06em; text-transform:uppercase }
.dir-b .space{ font-family:"Signika", var(--f-ui); font-size:@d(13); color:var(--m-side-ink2) }
.dir-b .bfoot{ display:flex; justify-content:space-between; align-items:baseline; padding:@d(10) @d(8) 0; box-shadow:inset 0 @d(1) 0 #333; font-size:@d(12); color:var(--m-side-ink2) }
.dir-b .bfoot b{ font:600 @d(16)/1 "Signika", var(--f-ui); color:var(--m-side-ink); font-variant-numeric:tabular-nums }
.dir-b .band{ background:var(--m-band); color:var(--m-band-ink); box-shadow:none; gap:@d(8) }
.dir-b .band .btn{ color:var(--m-band-ink) }
.dir-b .pict{ width:@d(34); height:@d(34); background:#0b0b0b; color:#fff; display:grid; place-items:center; border-radius:@d(3); flex:none }
.dir-b .pict .i{ width:@d(19); height:@d(19) }
.dir-b .dest{ flex:1; min-width:0; display:flex; align-items:baseline; gap:@d(8); font-family:"Signika", var(--f-ui); white-space:nowrap; overflow:hidden }
.dir-b .dest b{ font-size:@d(21); font-weight:650; letter-spacing:-.01em } .dir-b .dest small{ font-size:@d(14); font-weight:500; overflow:hidden; text-overflow:ellipsis }
.dir-b .moves{ display:flex; gap:@d(10); flex:none }
.dir-b .mv{ display:inline-flex; align-items:center; gap:@d(6); font:600 @d(12)/1 "Signika", var(--f-ui) }
.dir-b .mv .sq{ width:@d(24); height:@d(24); background:#0b0b0b; color:#fff; display:grid; place-items:center; border-radius:@d(2) }
.dir-b .mv .sq .i{ width:@d(14); height:@d(14) }
.dir-b .mv.on .sq{ background:#fff; color:#0b0b0b; box-shadow:inset 0 0 0 @d(2) #0b0b0b }
.dir-b .phbar{ background:var(--m-band); color:var(--m-band-ink); -webkit-backdrop-filter:none; backdrop-filter:none; gap:@p(10); padding:0 @p(8); border-radius:@p(10) }
.dir-b .phbar .pict{ width:@p(40); height:@p(40); border-radius:@p(4) } .dir-b .phbar .pict .i{ width:@p(22); height:@p(22) }
.dir-b .phbar .dest{ flex-direction:column; align-items:flex-start; gap:@p(2) }
.dir-b .phbar .dest b{ font-size:@p(19) } .dir-b .phbar .dest small{ font-size:@p(12.5) }
.dir-b .phbar .sq.n{ width:@p(40); height:@p(40); background:#0b0b0b; color:#fff; display:grid; place-items:center; border-radius:@p(4); font:650 @p(17)/1 "Signika", var(--f-ui) }
.dir-b .handoff{ border-radius:@p(6) }
.dir-b .drawer .dtab.on{ background:var(--m-band); color:var(--m-band-ink) }

/* C: the pack */
.dir-c .win{ background:transparent }
.dir-c .side{ -webkit-backdrop-filter:blur(@d(26)) saturate(1.7); backdrop-filter:blur(@d(26)) saturate(1.7) }
.dir-c .space{ font:650 @d(11)/1 "Archivo", var(--f-ui); font-stretch:87%; letter-spacing:.05em; text-transform:uppercase; padding:@d(7) @d(10) }
.dir-c .label{ font:650 @d(10)/1 "Archivo", var(--f-ui); font-stretch:87%; letter-spacing:.07em; text-transform:uppercase }
.dir-c .tab .w{ font-size:@d(11) }
.dir-c .tab .w.zz,.dir-c .zz{ color:var(--m-sleep) }
.dir-c .tab.on .w{ color:var(--m-live); font-weight:600 }
.pack{ padding:@d(12) @d(10) @d(12); border-radius:@d(12); background:var(--m-field); box-shadow:inset 0 0 0 @d(1) var(--m-rule) }
.pk-h{ display:flex; justify-content:space-between; align-items:baseline }
.pk-l{ font:700 @d(11)/1 "Archivo", var(--f-ui); font-stretch:87%; letter-spacing:.08em; text-transform:uppercase; color:var(--m-side-ink2) }
.pk-n{ font:500 @d(20)/1 "Martian Mono", var(--f-mono); letter-spacing:-.02em; color:var(--m-side-ink) } .pk-n small{ font-size:@d(11); color:var(--m-side-ink2) }
.pk-bar{ display:flex; gap:@d(2); height:@d(10); margin:@d(10) 0 @d(8); border-radius:@d(3); overflow:hidden; background:var(--m-rule) }
.pk-bar i{ display:block; height:100%; background:var(--m-live) }
.pk-bar i:nth-child(2){ opacity:.78 } .pk-bar i:nth-child(3){ opacity:.58 } .pk-bar i.p2{ background:var(--m-live); opacity:.4 }
.pk-bar i.s{ background:var(--m-side-ink2); opacity:.45 }
.pk-k{ display:flex; flex-direction:column; gap:@d(4); font:500 @d(10.5)/1.3 "Martian Mono", var(--f-mono); color:var(--m-side-ink2) }
.pk-k .zz{ display:inline-flex; align-items:center; gap:@d(5) } .pk-k .i{ width:@d(11); height:@d(11) }
.dir-c .addr{ background:var(--m-field) }
.dir-c .btn.on{ background:var(--m-live); color:#101418 }
.dir-c .phbar .pkm{ display:flex; flex-direction:column; justify-content:center; gap:@p(4); width:@p(64); flex:none; padding:0 @p(4) }
.dir-c .phbar .pkm b{ font:500 @p(13)/1 "Martian Mono", var(--f-mono); color:var(--m-ink) }
.dir-c .phbar .pkm i{ display:block; height:@p(5); border-radius:@p(3); background:var(--m-live) }
"""


def scale_units(css):
    css = re.sub(r"@d\((-?[\d.]+)\)", lambda m: f"{float(m.group(1)) / 10:g}cqw", css)
    return re.sub(r"@p\((-?[\d.]+)\)", lambda m: f"{float(m.group(1)) * 100 / 390:.3f}cqw", css)


# ---------------------------------------------------------------- page sections

def chart_rows(label, wk, cr):
    def row(name, pair, cls):
        lo, hi = pair
        return (f'<div class="row {cls}"><span class="rl">{name}</span><div class="track">'
                f'<span class="bar-min" style="width:{lo / 6.5:.2f}%"></span>'
                f'<span class="bar-rng" style="left:{lo / 6.5:.2f}%;width:{(hi - lo) / 6.5:.2f}%"></span></div>'
                f'<span class="rv">{rng(pair)} MB</span></div>')
    return f'<div class="grp"><div class="gl">{label}</div>{row("WebKit shell", wk, "a")}{row("Chrome", cr, "b")}</div>'


def ticks():
    spans = "".join(f'<span style="left:{v / 6.5:.2f}%">{v}</span>' for v in (0, 200, 400, 600))
    return f'<div class="axis"><span></span><div class="ticks">{spans}</div><span class="rv" style="color:var(--ink-3)">MB</span></div>'


def stack_row(name, cls, pages, rest):
    return (f'<div class="row {cls}"><span class="rl">{name}</span><div class="stack" style="width:{(pages + rest) / 6.5:.2f}%">'
            f'<i class="pg" style="width:{pages / (pages + rest) * 100:.2f}%"></i><i class="ov" style="flex:1"></i></div>'
            f'<span class="rv">{mb(pages + rest)} MB</span></div>')


FINDINGS = [
    ("crit", "Any website can crash it",
     "A chunk-size line of <code>ffffffffffffffff</code> makes the Rust shim panic in <code>dechunk</code> "
     "(<code>goosenet/src/lib.rs:166</code>). The panic crosses the <code>extern \"C\"</code> boundary, and that "
     "aborts the whole browser.",
     "Reproduced", "A local server sent that one response; the calling process exited with code 134."),
    ("crit", "A link longer than 200 bytes crashes it",
     "Every URL lives in a <code>u8[..200]</code> buffer, and Goose aborts when a bounded array overflows. Long links "
     "are everyday: search results, tracking links, shop pages.",
     "Language docs", "Goose reference, section 5.3: exceeding the capacity aborts. Not run, because the Goose build was blocked."),
    ("high", "Most real links go to the wrong address",
     "<code>resolve()</code> only joins a link to the current folder. On MDN, <code>/en-US/docs/Web/CSS</code> becomes "
     "<code>…/docs//en-US/docs/Web/CSS</code>; on <code>https://example.com</code>, <code>about.html</code> becomes the host "
     "<code>about.html</code>. Anchors, <code>//cdn</code> links and <code>mailto:</code> turn into page loads.",
     "Ran a port", "A line-for-line port of the function got five of seven common link types wrong."),
    ("high", "Redirects lose the page's address",
     "The shim follows redirects but hands back only the status and body, so links on a redirected page resolve "
     "against the address you typed.",
     "Code", "<code>goosenet_fetch</code> has no output for the final URL (<code>lib.rs:29</code>)."),
    ("high", "One dead link freezes navigation for 75 seconds",
     "All fetches share one worker and one queue, the connect has no timeout, and quitting waits for the worker.",
     "Measured", "75.0 s to an unreachable address, the macOS connect timeout."),
    ("med", "Paragraphs are cut to one line",
     "Wrapped text sits in fixed 20-pixel rows, so a paragraph shows its first line only.",
     "Screenshot", "Visible in the repo's own <code>screenshot.png</code>."),
    ("med", "It redraws at the screen's refresh rate while idle",
     "<code>gfx::frame()</code> is a game loop with vsync, so an idle window keeps the CPU and GPU busy.",
     "Language docs", "Goose gfx reference. Not measured."),
    ("low", "Every HTTPS request rebuilds the TLS setup",
     "It reloads the whole root-certificate store per request and speaks HTTP/1.0 with no keep-alive, compression, "
     "cookies or cache.",
     "Code", "<code>fetch_https</code> and <code>request_bytes</code> in <code>lib.rs</code>."),
]


def findings_html():
    sev = {"crit": "Critical", "high": "High", "med": "Medium", "low": "Low"}
    out = []
    for cls, title, body, tag, ev in FINDINGS:
        out.append(f'<li class="find {cls}"><span class="sev">{sev[cls]}</span><div><h3>{title}</h3>'
                   f'<p>{body}</p><p class="ev"><span class="tag">{tag}</span>{ev}</p></div></li>')
    return "".join(out)


SOURCES = [
    ("Arc: letter to members (May 2025)", "https://browsercompany.substack.com/p/letter-to-arc-members-2025"),
    ("Android Authority: Arc shuts down on 22 Dec (22 Oct 2026)", "https://www.androidauthority.com/arc-browser-shutting-down-december-2026-3726900/"),
    ("Google: vertical tabs in Chrome (7 Apr 2026)", "https://blog.google/products-and-platforms/products/chrome/new-chrome-productivity-features/"),
    ("Firefox 149 release notes (24 Mar 2026)", "https://www.firefox.com/en-US/firefox/149.0/releasenotes/"),
    ("Microsoft Edge: sleeping tabs (6 Dec 2022)", "https://blogs.windows.com/msedgedev/2022/12/06/sleeping-tabs-edge-105-sleep-before-discarding/"),
    ("CyberInsider: uBlock Origin removed from the Chrome Web Store (2026)", "https://cyberinsider.com/?p=339072"),
    ("Apple: iCloud data protection overview", "https://support.apple.com/en-us/102651"),
    ("Polypane", "https://polypane.app/"),
    ("Sizzy", "https://sizzy.co/"),
    ("Kagi: an update on Orion for Linux and Windows (2 Oct 2026)", "https://blog.kagi.com/update-orion-linux-windows"),
    ("Apple: alternative browser engines in the EU", "https://developer.apple.com/support/alternative-browser-engines/"),
    ("Apple: alternative browser engines in Japan", "https://developer.apple.com/support/alternative-browser-engines-jp/"),
    ("Open Web Advocacy: the DMA and browser engines (May 2026)", "https://open-web-advocacy.org/blog/the-digital-markets-act-is-delivering-real-wins-but-not-yet-for-browser-engines/"),
    ("Servo: Web Platform Tests dashboard", "https://servo.org/wpt/"),
    ("Ladybird newsletter (30 Sep 2026)", "https://ladybird.org/newsletter/2026-09-30"),
    ("Apple: WKWebExtensionController", "https://developer.apple.com/documentation/webkit/wkwebextensioncontroller"),
]


def page():
    s = {name: i + 1 for i, (name, _) in enumerate(SOURCES)}

    def cite(*names):
        return " ".join(f'<a href="{SOURCES[s[n] - 1][1]}">[{s[n]}]</a>' for n in names)

    arc, arcx, chrome, ff, edge, ubo, icloud, poly, sizzy, kagi, eu, jp, owa, servo, lady, ext = [n for n, _ in SOURCES]
    wk_pages, cr_pages = PAGES_WK, PAGES_CR
    dirs = "".join(direction_block(dd) for dd in DIRECTIONS)
    css = scale_units(DOC_CSS + MOCK_CSS + direction_css() + SIGNATURE_CSS)

    return f"""<title>Goose Browser Draft</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Familjen+Grotesk:wght@500;600;700&family=Atkinson+Hyperlegible+Next:wght@400;600;700&family=Spline+Sans+Mono:wght@400;500&family=Signika:wght@500;600;700&family=Archivo:wdth,wght@75..100,500..800&family=Martian+Mono:wght@400;500;600&display=swap">
<style>{css}</style>
{sprite()}
<header class="wrap top">
  <div class="brandrow"><span class="word">goose<small>working name</small></span>
    <span class="meta">Design draft 1 · 29 Oct 2026 · for Vlad and Gleb</span></div>
  <h1>Smooth, light, and on an engine we own</h1>
  <p class="lede">A private browser for the two of us: our own engine in Goose, with Rust for everything Goose lacks.
  It shows what each tab weighs, puts idle tabs to sleep, and opens a developer workbench with a project. This draft
  covers where the repo stands, what a browser weighs on your Mac, what the best browsers do in 2026, how our engine
  will work, and three directions for the interface.</p>
  <ul class="settled">
    <li>{ic("check")}Our own engine: Goose and Rust</li>
    <li>{ic("check")}Private, not distributed</li>
    <li>{ic("check")}Apple silicon: Mac, then iPhone</li>
    <li>{ic("check")}Smooth first</li>
    <li class="open">{ic("dots")}JavaScript engine, interface, name: open</li>
  </ul>
  <nav class="toc" aria-label="Sections"><a href="#repo">The repo today</a><a href="#weight">What a browser weighs</a>
    <a href="#recipe">What the best do</a><a href="#design">How our engine works</a><a href="#directions">Three directions</a>
    <a href="#next">What I need from you</a></nav>
</header>

<main>
<section id="repo" class="wrap">
  <h2>The repo today</h2>
  <div class="prose"><p>goose-mini-browser is a one-day learning demo. A window written in Goose scans a little HTML, and
  a small Rust library fetches pages over HTTP and HTTPS. The code is tidy and the README is honest about its limits. It
  proves Goose can open a window and fetch a page. For the engine we're building, nearly every part gets replaced: the
  scanner by a spec HTML parser, the Nuklear window by a Rust platform layer and GPU compositor, the fetch shim by a Rust
  network stack. The bugs below become the rules for that rebuild.</p></div>
  <ul class="facts"><li><b>1</b>commit, 29 Oct 2026</li><li><b>{GOOSE_LINES}</b>lines of Goose</li>
    <li><b>{RUST_LINES}</b>lines of Rust</li><li><b>0</b>tests, no CI</li><li><b>MIT</b>licence</li></ul>
  <ol class="findings">{findings_html()}</ol>
  <div class="two">
    <div><h3>Worth keeping</h3><ul>
      <li>An honest README that lists what the demo does not do.</li>
      <li>Fetches run off the UI thread, and stale results are dropped by request id.</li>
      <li>The headless <code>--frames N</code> mode, a ready-made screenshot test.</li>
      <li>rustls for TLS, with a body-size cap and read timeouts.</li></ul></div>
    <div><h3>Setup</h3><ul>
      <li>The README builds Goose from its main branch, which changed yesterday, and the language is two months old. Pin a commit.</li>
      <li><code>Cargo.lock</code> is ignored, so two builds can pull different crate versions.</li>
      <li>No tests or CI, although the headless mode is ready for them.</li>
      <li>The browser's header comment and both demo pages still say there is no networking.</li></ul></div>
  </div>
  <p class="note"><b>Measured since:</b> the demo builds and runs on your Mac. Left idle in a window it uses 13.8% CPU,
  redraws about 116 times a second, and holds 208–235 MB, about 175 MB of it GPU allocations.</p>
</section>

<section id="weight" class="wrap">
  <h2>What a browser weighs on your Mac</h2>
  <div class="prose"><p>I built an 80 KB WebKit shell (a window with web views and nothing else) and ran it beside a fresh
  Chrome with a throwaway profile, on the same pages, twice. Memory is Activity Monitor's figure, with memory shared
  between processes counted once.</p></div>
  <figure class="chart" aria-label="Memory of a bare WebKit shell and Chrome, one blank tab and three tabs">
    <h3>Total memory, low and high of two runs</h3>
    {chart_rows("One blank tab", BLANK_WK, BLANK_CR)}
    {chart_rows("Three tabs: example.com, MDN, GitHub", THREE_WK, THREE_CR)}
    {ticks()}
    <figcaption>The solid bar is the lower run; the pale extension reaches the higher one.</figcaption>
  </figure>
  <figure class="chart" aria-label="Where the memory goes with three tabs">
    <h3>Where it goes with three tabs (second run)</h3>
    <div class="grp">{stack_row("WebKit shell", "a", *SPLIT_RUN2["webkit"])}{stack_row("Chrome", "b", *SPLIT_RUN2["chrome"])}</div>
    {ticks()}
    <div class="legend"><span><i style="background:var(--ink-2)"></i>Solid: page processes ({mb(SPLIT_RUN2["webkit"][0])} MB in WebKit, {mb(SPLIT_RUN2["chrome"][0])} MB in Chrome)</span>
      <span><i style="background:repeating-linear-gradient(135deg, var(--ink-2) 0 3px, transparent 3px 7px)"></i>Striped: everything else ({mb(SPLIT_RUN2["webkit"][1])} MB in WebKit, {mb(SPLIT_RUN2["chrome"][1])} MB in Chrome)</span></div>
  </figure>
  <div class="reads">
    <p><b>The page is the weight.</b>GitHub's tab alone took {rng(GITHUB_RANGE)} MB across three runs, about three times
    the whole bare WebKit shell with a blank tab.</p>
    <p><b>Both engines pay the same for pages.</b>Page processes took {rng(wk_pages)} MB in WebKit and {rng(cr_pages)} MB
    in Chrome, whose count includes a spare renderer.</p>
    <p><b>The overhead is where they differ.</b>Everything else took {rng(REST_WK)} MB for WebKit and {rng(REST_CR)} MB for
    Chrome. With one blank tab Chrome already sits at {rng(BLANK_CR)} MB.</p>
  </div>
  <p class="so">These are the numbers our engine has to beat. Most of the weight is the pages, so ours must keep pages
  compact and put idle tabs to sleep.</p>
  <p class="method">MacBook Pro M5 Pro, 24 GB, macOS 26.5.1, 29 Oct 2026. Private sessions, 15 seconds to settle after
  loading, the last tab on screen. Chrome's figures include its spare renderer and, in the first run, its updater.
  Scripts and raw JSON: <code>design/measurements/</code>.</p>
</section>

<section id="recipe" class="wrap">
  <h2>What the best browsers do</h2>
  <div class="prose"><p>Two research passes on 29 Oct 2026. I checked every claim below against its source before
  using it.</p></div>
  <ul class="recipe">
    <li><h3>Familiar first, power on request</h3><p>Arc's own numbers: “Only 5.52% of DAUs use more than one Space
      regularly.” Its makers called it too different, with too much to learn. Arc stops working on 22 Dec 2026.</p>
      <p class="src-l">{cite(arc, arcx)}</p></li>
    <li><h3>Vertical tabs and split view are standard</h3><p>Chrome added native vertical tabs on 7 Apr 2026; Firefox 149
      added Split View on 24 Mar 2026. Neither is a reason to switch anymore.</p><p class="src-l">{cite(chrome, ff)}</p></li>
    <li><h3>Sleep idle tabs</h3><p>Microsoft measured an 83% average memory saving for each sleeping tab in Edge. Our own
      numbers say the pages are most of the weight.</p><p class="src-l">{cite(edge)}</p></li>
    <li><h3>Block ads inside the engine</h3><p>Google removed uBlock Origin from the Chrome Web Store in its last
      Manifest V2 purge. In our engine, blocking lives in the network layer, before a byte is parsed.</p>
      <p class="src-l">{cite(ubo)}</p></li>
    <li><h3>Sync privately</h3><p>Apple encrypts Safari history, Tab Groups and iCloud Tabs end to end. A new browser
      should promise no less.</p><p class="src-l">{cite(icloud)}</p></li>
    <li><h3>Developers want every viewport in sync</h3><p>Polypane shows every breakpoint side by side, all synced;
      Sizzy mirrors devices in one workspace for $15 a month. Both are separate Chromium apps.</p>
      <p class="src-l">{cite(poly, sizzy)}</p></li>
    <li><h3>Build only what you can keep secure</h3><p>Kagi ended Orion for Linux and Windows on 2 Oct 2026 to focus on
      macOS and iOS; Arc's makers cited the constant work of keeping a browser secure. Our answer is scope: two users,
      Mac and iPhone, documents first, in two memory-safe languages.</p><p class="src-l">{cite(kagi, arcx)}</p></li>
  </ul>
  <div class="side-by">
    <div class="ios"><h3>The iPhone rule, and why it doesn't bind us</h3>
      <p>Outside the EU and Japan, every browser in the App Store runs Apple's WebKit. The EU (iOS 17.4 and later) and
      Japan (iOS 26.2 and later) allow other engines only in separate, region-only apps that pass 90% of the Web Platform
      Tests. In May 2026 Open Web Advocacy reported that no vendor had shipped one in the EU.</p>
      <p>We aren't distributing, so we install our own engine on our own iPhones from Xcode. Two limits stay: apps can't
      JIT, so JavaScript runs interpreted, and iOS ends apps that use too much memory.</p>
      <p class="src-l">{cite(eu, jp, owa)}</p></div>
    <div><h3 style="margin-bottom:14px">What changed this year</h3><ol class="when">
      <li><time datetime="2026-03-24">24 Mar</time><span>Firefox 149 ships Split View and a free built-in VPN.</span></li>
      <li><time datetime="2026-04-07">7 Apr</time><span>Chrome gets native vertical tabs.</span></li>
      <li><time datetime="2026-09-01">1 Sep</time><span>CyberInsider reports Google has removed uBlock Origin from the Chrome Web Store.</span></li>
      <li><time datetime="2026-10-02">2 Oct</time><span>Kagi stops Orion for Linux and Windows.</span></li>
      <li><time datetime="2026-12-22">22 Dec</time><span>Arc stops working; its makers moved to Dia.</span></li></ol></div>
  </div>
  <div class="tablewrap"><table class="engines">
    <thead><tr><th>Engine</th><th>Where it stands</th><th>iPhone</th><th>For us</th></tr></thead>
    <tbody>
      <tr class="pick"><td>goose, ours</td><td>Goose for HTML, CSS, layout and paint; Rust for the platform layer, network, text, images and JavaScript. Documents first.</td><td class="yes">Yes, from Xcode</td><td>Building</td></tr>
      <tr><td>WebKit, from the OS</td><td>Safari's engine; web extensions for apps since macOS 15.4 and iOS 18.4. {mb(W_WIKI)} MB for the Focaccia article here.</td><td>Yes</td><td>The bar to beat</td></tr>
      <tr><td>Chromium</td><td>Best site compatibility and Chrome DevTools; {rng(BLANK_CR)} MB with one blank tab here.</td><td>EU and Japan only</td><td>Not used</td></tr>
      <tr><td>Servo</td><td>Rust, embeddable; passes 66.9% of WPT tests on its own dashboard (29 Oct 2026), up from 53.7% in April.</td><td>No port</td><td>A source of Rust modules</td></tr>
      <tr><td>Ladybird</td><td>A funded team, still preparing its first alpha for macOS and Linux (Sep 2026); mobile is not a focus.</td><td>No</td><td>Proof of how long an engine takes</td></tr>
    </tbody></table></div>
  <p class="src-l" style="margin-top:10px">{cite(servo, lady, ext)}</p>
</section>

<section id="design" class="wrap">
  <h2>How our engine works</h2>
  <div class="prose"><p>The full plan is in <code>docs/ENGINE.md</code>. In short: Goose owns the engine, Rust owns
  everything Goose lacks, and every frame is judged against 120 Hz. Apple silicon is the only target, so the engine
  leans on what it gives: one arm64 architecture, Metal, memory shared by CPU and GPU, and separate performance and
  efficiency cores.</p></div>
  <ul class="principles">
    <li><b>Smooth first</b><p>A frame is never late because of network, parsing or layout.</p></li>
    <li><b>Memory is a budget</b><p>Every part has a number, and the build fails when it goes over.</p></li>
    <li><b>Idle means zero</b><p>Nothing redraws, polls or runs while nothing changes.</p></li>
    <li><b>One renderer</b><p>The engine draws the pages and the browser's own interface.</p></li>
    <li><b>Documents first</b><p>Be the best at the pages we render before rendering more.</p></li>
  </ul>
  <div class="tablewrap"><table class="budget">
    <thead><tr><th>Test, on the 120 Hz M5 Pro</th><th>Pass</th><th>The bar today</th></tr></thead>
    <tbody>
      <tr><td>Scroll a long article for 10 seconds</td><td>Every frame under 8.3 ms, none dropped</td><td>Not measured yet</td></tr>
      <tr><td>Input to screen: a scroll, a key in the address bar</td><td>The next frame</td><td>Not measured yet</td></tr>
      <tr><td>A page loading in the background</td><td>Scrolling and typing never wait</td><td>The demo blocks for 75.0 s on a dead host</td></tr>
      <tr><td>Window idle, nothing animating</td><td>0% CPU, no frames drawn</td><td>Demo: 13.8% CPU, about 116 frames a second. M0: 0.0%, none</td></tr>
      <tr><td>An empty window</td><td>Under the bare WebKit shell</td><td>M0: 27.0 MB. WebKit shell: {rng(BLANK_WK)} MB. Demo: 208–235 MB</td></tr>
      <tr><td>Memory per tab</td><td>Shown in MB; budget set from the first measurement, then cut 20% per milestone</td><td>WebKit: {mb(W_WIKI)} MB for the Focaccia article</td></tr>
    </tbody></table></div>
  <ol class="flow" aria-label="One frame">
    <li><b>Input</b><p>The main thread sleeps until an event or a display tick wakes it.</p><span class="m">Rust · main thread</span></li>
    <li><b>Tab worker</b><p>Parse, DOM, style, layout, paint. Each tab is its own contained Goose worker.</p><span class="m">Goose · one per tab</span></li>
    <li><b>Compositor</b><p>Scrolls and animates from rasterized tiles, so a busy page never holds up a frame.</p><span class="m">Rust · Metal</span></li>
    <li><b>Present</b><p>Only when something changed. A sleeping tab is a worker that has ended.</p><span class="m">under 8.3 ms a frame</span></li>
  </ol>
  <div class="arch" aria-label="Who does what">
    <div class="full core"><b>Goose: the engine</b><span>The HTML tokenizer and tree builder (the WHATWG algorithm) · a DOM of compact inline nodes · CSS parsing, selectors and cascade · layout, block and inline first, then flex, grid and tables · a flat display list per frame · tabs, history, the sleep policy and the chrome's logic</span></div>
    <div><b>Rust: platform</b><span>Window, input, IME, the display link and the GPU compositor on Metal</span></div>
    <div><b>Rust: text</b><span>Core Text for fonts, fallback and shaping; glyphs rasterized into a GPU atlas in shared memory</span></div>
    <div><b>Rust: network</b><span>HTTP/1.1 and HTTP/2, TLS, cookies, cache, compression and ad blocking</span></div>
    <div><b>Rust: the rest</b><span>URLs, ImageIO and VideoToolbox decoding, storage, and the JavaScript engine after a bake-off</span></div>
    <div class="full os"><b>Two rules at the boundary</b><span>A Rust panic never crosses into Goose: every entry point returns an error code. Every tab is a contained worker, so a bad page ends its tab, never the browser.</span></div>
  </div>
  <div class="tablewrap" style="margin-top:34px"><table class="budget">
    <thead><tr><th>Milestone</th><th>Goal</th><th>Done when</th></tr></thead>
    <tbody>
      <tr><td>M0</td><td>Foundations</td><td>Goose pinned and built; CI with the headless screenshot test; a Rust window that waits for input and draws on demand at 0% idle CPU; one Goose and Rust frame on an iPhone. Done on 29 Oct except CI and the iPhone frame</td></tr>
      <tr><td>M1</td><td>One article, perfectly smooth</td><td>A saved copy of the Focaccia article scrolls 10 seconds with no dropped frame, its weight on screen</td></tr>
      <tr><td>M2</td><td>The live document web</td><td>Network, images, tabs as contained workers, sleep, and the chosen interface as our chrome</td></tr>
      <tr><td>M3</td><td>Layout breadth</td><td>Flex, grid, tables, positioning and forms, with Web Platform Tests as regression tests</td></tr>
      <tr><td>M4</td><td>JavaScript</td><td>A measured bake-off of Boa and QuickJS-ng, then DOM bindings, events and fetch</td></tr>
      <tr><td>M5</td><td>iPhone daily driver</td><td>Touch, the bottom bar, and sync with the Mac</td></tr>
    </tbody></table></div>
  <div class="devmode prose"><h3>Dev mode</h3>
    <p>It turns on when you open a project: a local server, a folder, or a site you mark as yours. Owning the engine
    makes it better than an embedded engine allows.</p>
    <ul>
      <li>Phone and desktop views of the same page, with scrolling and clicks mirrored between them.</li>
      <li>Open on iPhone: the Mac shares your local server with your paired iPhone over Wi-Fi.</li>
      <li>Every request with headers, bodies and timings, because the network stack is ours.</li>
      <li>A frame strip that marks any frame over 8.3 ms and names what caused it.</li>
      <li>The DOM, layout boxes and every tab's weight, live.</li>
    </ul></div>
</section>

<section id="directions" class="wrap">
  <h2>Three directions</h2>
  <p class="dirs-intro">One layout for all three, so the choice is about character. Each borrows four things from its world:
  type, colour, density and one signature move. The chrome will be HTML and CSS drawn by our own engine, so the winner
  becomes the first page the engine renders every day. Weights for
  Wikipedia, MDN, example.com and GitHub come from one measured run; the local site, the phone view and the iPhone figures
  are illustrative. Switch your system to dark mode to see each one at night.</p>
  {dirs}
  <div class="declined"><h3>Worlds I weighed and turned down</h3><ul>
    <li><b>Boarding pass and gate board</b><span>Read as a travel app. Station keeps its rows that move in place.</span></li>
    <li><b>Developer console</b><span>Read as a tool for developers only. Station keeps its folding panels.</span></li>
    <li><b>Botanical folio</b><span>Too far from a browser. Station keeps its single fixed scale.</span></li>
    <li><b>Orienteering map</b><span>Too niche. Station keeps one colour for the live tab.</span></li>
    <li><b>Data field</b><span>Too cold for everyday use. Station keeps its exact figures.</span></li>
  </ul></div>
</section>

<section id="next" class="wrap">
  <h2>What I need from you</h2>
  <ol class="asks">
    <li><b>Pick a direction.</b> A, B or C, or ask for three new ones. The winner becomes our chrome, written in HTML and
      CSS for our engine.</li>
    <li><b>Connect your personal GitHub.</b> Then I commit the plan, this draft and the measurements on a branch.</li>
    <li><b>The name.</b> goose is a working name; the Goose language and Block's goose agent already use it.</li>
  </ol>
  <p class="method">Not verified yet: CI, Goose on an iPhone, and the long-article scroll test. Images and video are
  Gleb's part.</p>
  <h3 style="margin-top:44px">Sources</h3>
  <ol class="sources">{"".join(f'<li><a href="{u}">{n}</a></li>' for n, u in SOURCES)}</ol>
</section>
</main>
<footer class="wrap">Design draft 1 · built from <code>design/build_draft.py</code> · engine plan in <code>docs/ENGINE.md</code> · product record in <code>PRODUCT.md</code></footer>
"""


if __name__ == "__main__":
    OUT.write_text(page())
    print(f"wrote {OUT} ({OUT.stat().st_size / 1024:.0f} KB)")
