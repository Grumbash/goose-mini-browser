// The network as a tab's worker sees it (docs/adr/0011, platform/src/net.rs
// and url.rs): URLs resolved as WHATWG says, and requests that end as a
// message in the tab's mailbox.

import std;
import engine from "../engine";
import engine.dom;

extern "tusk_platform" {
    fn tp_url_resolve(base: const u8[:], href: const u8[:], out: u8[:]) -> i32;
}

// `href` resolved against `base` (absolute), onto the end of `out`; false,
// and nothing added, when it doesn't resolve.
fn resolve_url(base: const u8[:], href: const u8[:], out: u8[>..]&) -> bool {
    let n = tp_url_resolve(base, href, out[0..0]);
    guard n >= 0 else { return false; }
    let at = out.len;
    for k in n { out.push(0); }       // pushed, not resized: a resize may shrink
    return tp_url_resolve(base, href, out[at..]) == n;
}

// What the relative URLs of document `d`, loaded from `url`, resolve against,
// onto the end of `out`: its <base href> resolved against `url`, or `url`.
fn doc_base(d: Doc, url: const u8[:], out: u8[>..]&) {
    let href, has = base_href(d);
    if has && resolve_url(url, href, out) { return; }
    out.append(url);
}
