// The network as a tab's worker sees it (docs/adr/0011, platform/src/net.rs
// and url.rs): URLs resolved as WHATWG says, and requests that end as a
// message in the tab's mailbox.

import std;
import engine from "../engine";
import engine.dom;

// What a request is for, the profiles (docs/adr/0008) and tp_net_open's
// flags, as platform/src/net.rs numbers them.
let NET_DOCUMENT: i32 = 1;
let NET_STYLE: i32 = 2;
let NET_IMAGE: i32 = 3;
let PROFILE_SANDBOX: i32 = 0;    // keeps nothing: tests, screenshots, snapshots, agents
let PROFILE_DEFAULT: i32 = 1;    // ours
let NET_RELOAD: i32 = 1;         // past the cache
let ERR_BLOCKED: i32 = -6;       // a URL the page may not load

// A request's state: its id, the HTTP status, why it failed (0 when it
// didn't), what it is for, how many bytes its body, final URL, MIME type and
// error text have, and the body's expected size (-1 when unknown).
struct NetHead { req: i32, status: i32, error: i32, kind: i32, body: i64, url: i64, mime: i64, text: i64, expected: i64 }

// A request in a page's network log: its id, what it was for, its HTTP
// status and why it failed (0 when it didn't), its protocol (1 HTTP/1.1, 2
// HTTP/2, 3 HTTP/3, 0 not known), flags (ROW_), its body's bytes and those
// over the wire, where its URL is in the log's text, and its times in ms:
// when it started after the page's first, looking up, connecting, TLS,
// waiting for the first byte, the download, and in all.
struct NetRow {
    req: i32, kind: i32, status: i32, error: i32, proto: i32, flags: i32, bytes: i64, wire: i64, url_at: i64,
    url_len: i64, start: f32, dns: f32, connect: f32, tls: f32, wait: f32, download: f32, total: f32,
}
let ROW_REUSED: i32 = 1;         // on a connection already open
let ROW_CACHED: i32 = 2;         // from the cache
let ROW_TIMED: i32 = 4;          // its times have come

extern "tusk_platform" {
    fn tp_url_resolve(base: const u8[:], href: const u8[:], out: u8[:]) -> i32;
    fn tp_net_start(profile: i32) -> i32;
    fn tp_net_open(tab: i32, profile: i32, kind: i32, url: const u8[:], from: const u8[:], flags: i32) -> i32;
    fn tp_net_head(req: i32, out: NetHead&) -> i32;
    fn tp_net_take(req: i32, body: u8[:], url: u8[:], mime: u8[:], text: u8[:]) -> i32;
    fn tp_net_cancel(req: i32) -> i32;
    fn tp_net_progress(tab: i32, received: i64&, expected: i64&) -> i32;
    fn tp_open_in_safari(url: const u8[:]) -> i32;
    fn tp_file_size(path: const u8[:]) -> i64;
    fn tp_net_storage(dir: const u8[:]) -> i32;
    fn tp_net_log_size(tab: i32, rows: i64&, bytes: i64&) -> i32;
    fn tp_net_log(tab: i32, rows: NetRow[:], urls: u8[:]) -> i32;
    fn tp_net_save() -> i32;
}

// Whether `loc` is a web address, http or https, rather than a file's path.
fn is_web(loc: const u8[:]) -> bool {
    var scheme: u8[>..] = [];
    for c in loc {
        if c == ':' { break; }
        scheme.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c });
    }
    return (scheme[..] == "http" || scheme[..] == "https") && scheme.len < loc.len;
}

// Takes ended request `req`, whose head is in `head`: its body, final URL,
// MIME type and error text onto the ends of those arrays. False if it isn't
// there to take.
fn take_net(req: i32, head: NetHead&, body: u8[>..]&, url: u8[>..]&, mime: u8[>..]&, text: u8[>..]&) -> bool {
    guard tp_net_head(req, head) == 1 else { return false; }
    let b = body.len;
    let u = url.len;
    let m = mime.len;
    let t = text.len;
    body.resize(b + head.body, 0);
    url.resize(u + head.url, 0);
    mime.resize(m + head.mime, 0);
    text.resize(t + head.text, 0);
    return tp_net_take(req, body[b..], url[u..], mime[m..], text[t..]) == 0;
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

// Page `page`'s network log onto `rows` and `urls`, which it replaces;
// nothing for no page (-1) or one that logged nothing.
fn read_log(page: i32, rows: NetRow[>..]&, urls: u8[>..]&) {
    rows.resize(0);
    urls.resize(0);
    guard page >= 0 else { return; }
    var n: i64 = 0;
    var bytes: i64 = 0;
    guard tp_net_log_size(page, n, bytes) == 0 && n > 0 else { return; }
    let blank = NetRow { req: 0, kind: 0, status: 0, error: 0, proto: 0, flags: 0, bytes: 0, wire: 0, url_at: 0,
                         url_len: 0, start: 0.0, dns: 0.0, connect: 0.0, tls: 0.0, wait: 0.0, download: 0.0, total: 0.0 };
    for k in n { rows.push(blank); }
    for k in bytes { urls.push(0); }
    // The log may have grown meanwhile: then none of it, until the next time.
    if tp_net_log(page, rows[..], urls[..]) != 0 {
        rows.resize(0);
        urls.resize(0);
    }
}
