// A tab's page (docs/adr/0010). Each runs in a contained worker that owns its
// document, so a page that fails ends its tab only, and the main thread never
// lays a page out. The worker loads, parses, styles and measures the page,
// then lays it out for each size the main thread posts, and hands the display
// list over in one copy (platform/src/tabs.rs). It answers hit tests and
// snapshot requests from the list as laid out last. It also lists the page's
// elements once, for the dev panel.

import std;
import os;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.css;
import engine.layout;
import engine.snapshot;
import engine.hit;
import .net;
import .sheets;

// A message to a tab, as platform/src/tabs.rs numbers them.
struct TabMsg { kind: i32, a: f32, b: f32, c: f32 }
let MSG_SIZE: i32 = 1;       // a: width, b: the view's height, c: backing scale
let MSG_HIT: i32 = 2;        // a, b: a point on the page
let MSG_SNAPSHOT: i32 = 3;   // a: the width to lay the page out at, b: the view's height
let MSG_QUIT: i32 = 4;
let MSG_NET: i32 = 5;        // a: a request that ended (platform/src/net.rs)
let MSG_CLICK: i32 = 6;      // a, b: a point on the page; c: 1 to open a link there in a new tab

// What a display list comes with: the page's height and canvas colour, its
// size in nodes and bytes, what each stage took in milliseconds, the backing
// scale it is for, and how long reading the file took.
struct FrameInfo {
    height: f32, background: u32, nodes: i32, bytes: i32,
    parse: f32, style: f32, measure: f32, layout: f32, scale: f32, read: f32,
}

// A reply's kind, number and length of text.
struct ReplyHead { kind: i32, value: i32, len: i64 }
let REPLY_HIT: i32 = 1;      // value: the pointer shape over the point
let REPLY_TITLE: i32 = 2;    // text: the page's title
let REPLY_SNAPSHOT: i32 = 3; // text: the page as a tree for agents
let REPLY_FAILED: i32 = 4;   // text: why the page didn't load
let REPLY_ELEMENTS: i32 = 5; // text: its elements under <body>, a line each (elements_of)
let REPLY_READ: i32 = 6;     // value: the document's size in bytes, once read
let REPLY_URL: i32 = 7;      // value: the HTTP status; text: the page's URL after redirects
let REPLY_LOG: i32 = 8;      // text: what went wrong loading the page, a line each
let REPLY_LINK: i32 = 9;     // value: 1 for a new tab; text: the URL a clicked link leads to
let REPLY_JUMP: i32 = 10;    // value: where on the page to scroll to (-1: nowhere); text: the URL with its fragment
let REPLY_GONE: i32 = 11;    // the worker has ended

// How much of a page's own text the interface takes: a page's title or an
// element's id or class could be any length, and the interface is laid out
// again whenever it changes.
let TITLE_MAX: i64 = 256;
let NAME_MAX: i64 = 80;

// Pointer shapes, as numbered in platform/src/lib.rs.
let CURSOR_ARROW: i32 = 0;
let CURSOR_POINTER: i32 = 1;

extern "tusk_platform" {
    fn tp_tab_open(tab: i32) -> i32;
    fn tp_tab_drop(tab: i32) -> i32;
    fn tp_tab_post(tab: i32, msg: const TabMsg&) -> i32;
    fn tp_tab_next(tab: i32, timeout_ms: i64, out: TabMsg&) -> i32;
    fn tp_post_frame(tab: i32, items: const DItem[:], text: const u8[:], paths: const f32[:], info: const FrameInfo&) -> i32;
    fn tp_post_reply(tab: i32, kind: i32, value: i32, text: const u8[:]) -> i32;
    fn tp_take_frame(tab: i32, layer: i32, info: FrameInfo&) -> i32;
    fn tp_reply_head(tab: i32, out: ReplyHead&) -> i32;
    fn tp_take_reply(tab: i32, out: ReplyHead&, text: u8[:]) -> i32;
    fn tp_wait_tab(tab: i32, timeout_ms: i64) -> i32;
}

// The page once parsed, styled and measured: what layout at any width needs.
struct Page {
    d: Doc,
    styles: Style[>..]&,
    text: u8[>..]&,
    carets: f32[>..]&,
    runs: Run[>..]&,
    run_of: i32[>..]&,
    fonts: FontInfo[>..]&,
}

// What the main thread knows of a tab: its page's worker and mailbox (-1
// for none: stopped); what came with its last display list (`ready` once one
// has) and what taking it cost there; whether it failed; whether a display
// list waits to be taken when it is shown; how far it is scrolled, and where
// to scroll once its page comes (-1: the top); when it opened and how long it
// took to show; its page's HTTP status (0 for a file); its place in history
// (an entry, tusk.goose); and spans of the main thread's notes: where it is
// (a file's path or a URL), its title, why it failed, what went wrong loading
// it (a line each), its elements.
struct Tab {
    worker: i64, page: i32, ready: bool, failed: bool, info: FrameInfo, paint: f32, waiting: bool, scroll: f32,
    restore: f32, opened: i64, load_ms: f32, status: i32, entry: i64, loc_at: i64, loc_len: i64, title_at: i64,
    title_len: i64, why_at: i64, why_len: i64, log_at: i64, log_len: i64, elems_at: i64, elems_len: i64,
}

// How fetching a document ended.
let LOAD_OK: i32 = 0;
let LOAD_FAILED: i32 = 1;    // the main thread was told why
let LOAD_QUIT: i32 = 2;      // the tab closed meanwhile

fn ms_since(from: i64) -> f32 { return ((clock_ns() - from) / 1000000.0) as f32; }

// The worker of page `tab` (its mailbox), for the page at `loc`: a file's
// path, or an http or https URL, loaded on profile `profile`'s session, past
// the cache when `reload` says so. Its media queries see dark mode when
// `dark` does. It says when it has ended, so the main thread can let it go
// without waiting for it.
thread_fn tab_worker(tab: i32, loc: u8[>..], profile: i32, dark: bool, reload: bool) {
    show_page(tab, loc[..], profile, dark, reload);
    tp_post_reply(tab, REPLY_GONE, 0, "");
}

fn show_page(tab: i32, loc: const u8[:], profile: i32, dark: bool, reload: bool) {
    var src: u8[>..] = [];
    var later: TabMsg[>..] = [];     // what the main thread asked while the page came
    var page: u8[>..] = [];          // the page's URL, after redirects
    var t = clock_ns();
    let flags = if reload { NET_RELOAD } else { 0 };
    if is_web(loc) {
        let got = fetch_document(tab, profile, loc, flags, src, page, later);
        guard got != LOAD_QUIT else { return; }
        guard got == LOAD_OK else { serve_nothing(tab); return; }
    } else {
        guard read_file(loc, src) else {
            tp_post_reply(tab, REPLY_FAILED, 0, str("can't read ", loc)[..]);
            serve_nothing(tab);
            return;
        }
        file_url(loc, page);
    }
    var info = FrameInfo { height: 0.0, background: 0xFFFFFFFF, nodes: 0, bytes: src.len as i32,
                           parse: 0.0, style: 0.0, measure: 0.0, layout: 0.0, scale: 1.0, read: ms_since(t) };
    tp_post_reply(tab, REPLY_READ, src.len as i32, "");
    t = clock_ns();
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(src[..], d);
    info.parse = ms_since(t);
    // Its sheets, fetched while nothing shows: the wait counts as reading.
    t = clock_ns();
    var base: u8[>..] = [];
    doc_base(d, page[..], base);
    var sheet_texts: u8[>..] = [];
    var sheet_ends: i64[>..] = [];
    var sheet_medias: u8[>..] = [];
    var sheet_media_ends: i64[>..] = [];
    var log: u8[>..] = [];
    guard gather_sheets(tab, profile, flags, d, page[..], base[..], sheet_texts, sheet_ends, sheet_medias,
                        sheet_media_ends, later, log) else { return; }
    if log.len > 0 { tp_post_reply(tab, REPLY_LOG, 0, log[..]); }
    info.read += ms_since(t);
    t = clock_ns();
    var rules: Rule[>..] = [];
    var comps: Compound[>..] = [];
    var classes: Span[>..] = [];
    var decls: Decl[>..] = [];
    var sheet_bytes: u8[>..] = [];
    var sel_attrs: AttrSel[>..] = [];
    var vars: Var[>..] = [];
    var var_bytes: u8[>..] = [];
    var media: Media[>..] = [];
    let sh = Sheet { rules: rules, comps: comps, classes: classes, attrs: sel_attrs, decls: decls, bytes: sheet_bytes,
                     vars: vars, var_bytes: var_bytes, media: media };
    load_sheets_with(d, sh, sheet_texts[..], sheet_ends[..], sheet_medias[..], sheet_media_ends[..]);
    // Styled for the viewport the main thread asked for while the page came,
    // or else the design's window.
    var env = MediaEnv { width: 1200.0, height: 760.0, scale: 2.0, dark: dark };
    for m in later { if m.kind == MSG_SIZE { env = MediaEnv { width: m.a, height: m.b, scale: m.c, dark: dark }; } }
    set_media(sh, env);
    var styles: Style[>..] = [];
    compute_styles(d, sh, styles);
    info.style = ms_since(t);
    t = clock_ns();
    var text: u8[>..] = [];
    var carets: f32[>..] = [];
    var runs: Run[>..] = [];
    var run_of: i32[>..] = [];
    var fonts: FontInfo[>..] = [];
    let P = Page { d: d, styles: styles, text: text, carets: carets, runs: runs, run_of: run_of, fonts: fonts };
    measure_page(P);
    info.measure = ms_since(t);
    info.nodes = nodes.len as i32;
    info.background = background_of(P);
    var title: u8[>..] = [];
    for n, k in nodes {
        if n.kind == NODE_ELEMENT && n.first >= 0 && node_name(d, k as i32) == "title" && styles[k].svg == 0 {
            one_line(title, node_text(d, n.first), TITLE_MAX);
            break;
        }
    }
    tp_post_reply(tab, REPLY_TITLE, 0, title[..]);
    var elems: u8[>..] = [];
    elements_of(d, elems);
    tp_post_reply(tab, REPLY_ELEMENTS, 0, elems[..]);
    serve(tab, P, sh, env, info, later[..], base[..], page[..]);
}

// Loads the document at `url` on profile `profile`'s session into `src`, as
// HTML: a text response goes in a <pre>. Its URL after redirects goes onto
// `page` and to the main thread, with its status; or why it failed. What the
// main thread asks meanwhile goes in `later`, to answer once there is a page.
fn fetch_document(tab: i32, profile: i32, url: const u8[:], flags: i32, src: u8[>..]&, page: u8[>..]&,
                  later: TabMsg[>..]&) -> i32 {
    let req = tp_net_open(tab, profile, NET_DOCUMENT, url, "", flags);
    guard req > 0 else {
        tp_post_reply(tab, REPLY_FAILED, 0, str("can't load ", url)[..]);
        return LOAD_FAILED;
    }
    guard wait_net(tab, req, later) else {
        tp_net_cancel(req);
        return LOAD_QUIT;
    }
    var head = NetHead { req: 0, status: 0, error: 0, kind: 0, body: 0, url: 0, mime: 0, text: 0, expected: 0 };
    var body: u8[>..] = [];
    var final_url: u8[>..] = [];
    var mime: u8[>..] = [];
    var why: u8[>..] = [];
    guard take_net(req, head, body, final_url, mime, why) else {
        tp_post_reply(tab, REPLY_FAILED, 0, str("can't load ", url)[..]);
        return LOAD_FAILED;
    }
    guard head.error == 0 else {
        tp_post_reply(tab, REPLY_FAILED, 0, why[..]);
        return LOAD_FAILED;
    }
    tp_post_reply(tab, REPLY_URL, head.status, final_url[..]);
    page.append(final_url);
    let m = mime[..];
    if m.len == 0 || m == "text/html" || m == "application/xhtml+xml" {
        src.append(body);
    } else if starts_with(m, "text/") || m == "application/json" || ends_with(m, "+json") || ends_with(m, "+xml")
              || m == "application/xml" || m == "application/javascript" {
        src.append("<!doctype html><meta charset=\"utf-8\"><pre>");
        for c in body {
            if c == '&' { src.append("&amp;"); } else if c == '<' { src.append("&lt;"); } else { src.push(c); }
        }
        src.append("</pre>");
    } else {
        tp_post_reply(tab, REPLY_FAILED, 0, str("Tusk can't show ", m, " yet: ⌘⇧S opens it in Safari")[..]);
        return LOAD_FAILED;
    }
    return LOAD_OK;
}

// Waits for request `req` of tab `tab` to end. Meanwhile a hit test is
// answered with an arrow, and what else the main thread asks goes in
// `later`. False if the tab quits first.
fn wait_net(tab: i32, req: i32, later: TabMsg[>..]&) -> bool {
    var m = TabMsg { kind: 0, a: 0.0, b: 0.0, c: 0.0 };
    loop {
        // A mailbox that fails (closed under it) ends the worker.
        let got = tp_tab_next(tab, -1, m);
        guard got >= 0 else { return false; }
        guard got == 1 else { continue; }
        if m.kind == MSG_QUIT { return false; }
        if m.kind == MSG_NET {
            if m.a as i32 == req { return true; }
        } else if m.kind == MSG_HIT {
            tp_post_reply(tab, REPLY_HIT, CURSOR_ARROW, "");
        } else {
            later.push(m);
        }
    }
    return false;
}

// The elements under <body>, <body> first, in document order, at most 200, onto
// `out`: a line each of its depth, name, id and classes, apart by tabs.
fn elements_of(d: Doc, out: u8[>..]&) {
    var body: i32 = -1;
    for n, k in d.nodes {
        if n.kind == NODE_ELEMENT && node_name(d, k as i32) == "body" {
            body = k as i32;
            break;
        }
    }
    guard body >= 0 else { return; }
    var n = body;
    var depth = 0;
    var count = 0;
    loop {
        if d.nodes[n].kind == NODE_ELEMENT {
            format(out, depth, "\t", node_name(d, n), "\t");
            let id, has_id = attr_value(d, n, "id");
            if has_id { one_line(out, id, NAME_MAX); }
            out.push('\t');
            let classes, has_classes = attr_value(d, n, "class");
            if has_classes { one_line(out, classes, NAME_MAX); }
            out.push('\n');
            count += 1;
            guard count < 200 else { return; }
        }
        // On to the next node: down into an element, or on, or back up.
        if d.nodes[n].kind == NODE_ELEMENT && d.nodes[n].first >= 0 {
            n = d.nodes[n].first;
            depth += 1;
            continue;
        }
        while n != body && d.nodes[n].next < 0 {
            n = d.nodes[n].parent;
            depth -= 1;
        }
        guard n != body else { return; }
        n = d.nodes[n].next;
    }
}

// s onto out as one line, at most `max` bytes: its runs of white space as
// one space, none at its ends, and cut before a character that wouldn't fit.
fn one_line(out: u8[>..]&, s: const u8[:], max: i64) {
    let start = out.len;
    var space = false;
    for c in s {
        let blank = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0c';
        if blank {
            space = out.len > start;
            continue;
        }
        // A character's first byte: it and the rest of it must fit.
        if (c & 0xC0) != 0x80 {
            let n: i64 = if c >= 0xF0 { 4 } else if c >= 0xE0 { 3 } else if c >= 0xC0 { 2 } else { 1 };
            let room = out.len - start + (if space { 1 } else { 0 }) + n;
            if room > max { break; }
            if space { out.push(' '); }
            space = false;
        } else if out.len - start >= max {
            break;    // a byte that starts no character, past the end
        }
        out.push(c);
    }
}

// Answers the main thread for page P until it says quit: a display list for
// each size, the pointer's shape for each point, a tree for each snapshot.
// What it asked while the page came, `later`, is answered first. A size that
// turns one of its sheets' @media on or off styles and measures it again
// first, against sheets `sh`, for viewport `env`. A click on a link says
// where it leads, its URL resolved against `base`, the page being `page`.
fn serve(tab: i32, P: Page, sh: Sheet, env: MediaEnv, info: FrameInfo&, later: const TabMsg[:], base: const u8[:],
         page: const u8[:]) {
    var viewport = env;
    var items: DItem[>..<] = [];     // the display list as laid out last, for hit tests
    var bounds: f32[>..<] = [];      // where its items are: made at the first hit test after a layout
    var bounded = false;
    var paths: f32[>..<] = [];
    var m = TabMsg { kind: 0, a: 0.0, b: 0.0, c: 0.0 };
    var next: i64 = 0;
    loop {
        if next < later.len {
            m = later[next];
            next += 1;
        } else {
            // A mailbox that fails (closed under it) ends the worker.
            let got = tp_tab_next(tab, -1, m);
            guard got >= 0 else { return; }
            guard got == 1 else { continue; }
        }
        if m.kind == MSG_QUIT { return; }
        if m.kind == MSG_SIZE {
            viewport = MediaEnv { width: m.a, height: m.b, scale: m.c, dark: viewport.dark };
            if set_media(sh, viewport) {
                let t0 = clock_ns();
                compute_styles(P.d, sh, P.styles);
                info.style = ms_since(t0);
                // Measured again: new runs go after the old, and each node
                // points at its new one. The old stay until the page goes, a
                // copy of its text for each flip.
                let t1 = clock_ns();
                measure_page(P);
                info.measure = ms_since(t1);
                info.background = background_of(P);
            }
            let t = clock_ns();
            info.height = lay_out(P, items, paths, m.a, m.b);
            info.layout = ms_since(t);
            info.scale = m.c;
            bounded = false;
            tp_post_frame(tab, items[..], P.text[..], paths[..], info);
        } else if m.kind == MSG_HIT {
            if !bounded {
                hit_bounds(items[..], P.fonts[..], bounds);
                bounded = true;
            }
            let link = link_at(P.d, node_at(items[..], P.fonts[..], bounds[..], m.a, m.b));
            tp_post_reply(tab, REPLY_HIT, if link >= 0 { CURSOR_POINTER } else { CURSOR_ARROW }, "");
        } else if m.kind == MSG_CLICK {
            if !bounded {
                hit_bounds(items[..], P.fonts[..], bounds);
                bounded = true;
            }
            let link = link_at(P.d, node_at(items[..], P.fonts[..], bounds[..], m.a, m.b));
            if link >= 0 { follow(tab, P, items[..], base, page, link, m.c != 0.0); }
        } else if m.kind == MSG_SNAPSHOT {
            var out: u8[>..] = [];
            snapshot_of(P, m.a, m.b, info, out);
            tp_post_reply(tab, REPLY_SNAPSHOT, 0, out[..]);
        }
    }
}

// Where a click on link `link` of page P (at `page`, its URLs resolving
// against `base`) leads, to the main thread. A link to a place on this page
// jumps there, unless it opens in a new tab. A web page's links lead to the
// web; a file's to the web or to files. javascript:, mailto: and the rest do
// nothing yet.
fn follow(tab: i32, P: Page, items: const DItem[:], base: const u8[:], page: const u8[:], link: i32, new_tab: bool) {
    let href, has = attr_value(P.d, link, "href");
    guard has else { return; }
    var url: u8[>..] = [];
    guard resolve_url(base, href, url) else { return; }
    let file = starts_with(url[..], "file:");
    guard is_web(url[..]) || (file && !is_web(page)) else { return; }
    let hash = find(url[..], "#");
    var page_end = find(page, "#");
    if page_end < 0 { page_end = page.len; }
    if hash >= 0 && !new_tab && url[..hash] == page[..page_end] {
        tp_post_reply(tab, REPLY_JUMP, fragment_y(P, items, url[hash + 1..]), url[..]);
        return;
    }
    tp_post_reply(tab, REPLY_LINK, if new_tab { 1 } else { 0 }, url[..]);
}

// Where on page P fragment `frag` is (HTML §7.4.6.4): the top for none or
// "top"; else the element whose id it is, or the <a> it names, as high as
// its first item, or the first after it; -1 for none.
fn fragment_y(P: Page, items: const DItem[:], frag: const u8[:]) -> i32 {
    var name: u8[>..] = [];
    if !percent_decoded(frag, name) { name.resize(0); name.append(frag); }
    guard name.len > 0 && !same_word(name[..], "top") else { return 0; }
    var target: i32 = -1;
    for n, k in P.d.nodes {
        guard n.kind == NODE_ELEMENT else { continue; }
        let id, has = attr_value(P.d, k as i32, "id");
        if has && id == name[..] { target = k as i32; break; }
    }
    if target < 0 {
        for n, k in P.d.nodes {
            guard n.kind == NODE_ELEMENT && node_name(P.d, k as i32) == "a" else { continue; }
            let a, has = attr_value(P.d, k as i32, "name");
            if has && a == name[..] { target = k as i32; break; }
        }
    }
    guard target >= 0 else { return -1; }
    // Nodes are in document order: the first item of it or after it.
    var best: i32 = -1;
    var y: f32 = 0.0;
    for it in items {
        guard it.node >= target else { continue; }
        if best < 0 || it.node < best || (it.node == best && it.y < y) {
            best = it.node;
            y = it.y;
        }
    }
    return if best < 0 { -1 } else { max(y, 0.0) as i32 };
}

// For a page that didn't load: answers until quit, with nothing to show.
fn serve_nothing(tab: i32) {
    var m = TabMsg { kind: 0, a: 0.0, b: 0.0, c: 0.0 };
    loop {
        let got = tp_tab_next(tab, -1, m);
        guard got >= 0 else { return; }
        guard got == 1 else { continue; }
        if m.kind == MSG_QUIT { return; }
        if m.kind == MSG_HIT { tp_post_reply(tab, REPLY_HIT, CURSOR_ARROW, ""); }
        if m.kind == MSG_SNAPSHOT { tp_post_reply(tab, REPLY_SNAPSHOT, 0, ""); }
    }
}

fn measure_page(P: Page) {
    var boxes: Rect[>..] = [];
    var items: DItem[>..<] = [];
    var flex: FlexItem[>..<] = [];
    var atoms: i32[>..<] = [];
    var measured: Measured[>..] = [];
    var paths: f32[>..<] = [];
    var ids: i32[>..] = [];
    var definite: f32[>..] = [];
    let L = Layout { d: P.d, styles: P.styles, text: P.text, carets: P.carets, runs: P.runs, run_of: P.run_of,
                     fonts: P.fonts, boxes: boxes, items: items, flex: flex, atoms: atoms,
                     measured: measured, paths: paths, ids: ids, definite: definite };
    measure(L);
}

// Lays page P out `width` points wide, for a view `view_h` points high, into
// `items` and `paths`. Returns the page's height.
fn lay_out(P: Page, items: DItem[>..<]&, paths: f32[>..<]&, width: f32, view_h: f32) -> f32 {
    var boxes: Rect[>..] = [];
    var flex: FlexItem[>..<] = [];
    var atoms: i32[>..<] = [];
    var measured: Measured[>..] = [];
    var ids: i32[>..] = [];
    var definite: f32[>..] = [];
    items.resize(0);
    paths.resize(0);
    let L = Layout { d: P.d, styles: P.styles, text: P.text, carets: P.carets, runs: P.runs, run_of: P.run_of,
                     fonts: P.fonts, boxes: boxes, items: items, flex: flex, atoms: atoms,
                     measured: measured, paths: paths, ids: ids, definite: definite };
    return layout_page(L, width, view_h);
}

// Page P as a tree for agents, laid out `width` × `view_h`, onto `out`; what
// it cost goes to stderr.
fn snapshot_of(P: Page, width: f32, view_h: f32, info: FrameInfo, out: u8[>..]&) {
    var boxes: Rect[>..] = [];
    var items: DItem[>..<] = [];
    var flex: FlexItem[>..<] = [];
    var atoms: i32[>..<] = [];
    var measured: Measured[>..] = [];
    var paths: f32[>..<] = [];
    var ids: i32[>..] = [];
    var definite: f32[>..] = [];
    let L = Layout { d: P.d, styles: P.styles, text: P.text, carets: P.carets, runs: P.runs, run_of: P.run_of,
                     fonts: P.fonts, boxes: boxes, items: items, flex: flex, atoms: atoms,
                     measured: measured, paths: paths, ids: ids, definite: definite };
    let t0 = clock_ns();
    let h = layout_page(L, width, view_h);
    let t1 = clock_ns();
    let entries = snapshot(L, width, h, out);
    var note: u8[>..] = [];
    format(note, "snapshot: ", entries, " entries, ");
    format_flt(note, out.len / 1000.0, 1);
    format(note, " KB from ", (info.bytes + 500) / 1000, " KB of HTML; parse ");
    format_flt(note, info.parse, 1);
    note.append(" + style ");
    format_flt(note, info.style, 1);
    note.append(" + text ");
    format_flt(note, info.measure, 1);
    note.append(" + layout ");
    format_flt(note, ((t1 - t0) / 1000000.0) as f32, 1);
    note.append(" + tree ");
    format_flt(note, ms_since(t1), 1);
    note.append(" ms\n");
    write_stderr(note);
}

// The canvas takes the root element's background, or else the body's (CSS
// 2.2 §14.2); white if neither has one.
fn background_of(P: Page) -> u32 {
    let html = P.d.nodes[0].first;
    guard html >= 0 else { return 0xFFFFFFFF; }
    if (P.styles[html].bg >> 24) != 0 { return P.styles[html].bg; }
    var c = P.d.nodes[html].first;
    while c >= 0 {
        if is_element(P.d, c, "body") && (P.styles[c].bg >> 24) != 0 { return P.styles[c].bg; }
        c = P.d.nodes[c].next;
    }
    return 0xFFFFFFFF;
}
