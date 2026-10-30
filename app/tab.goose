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

// A message to a tab, as platform/src/tabs.rs numbers them.
struct TabMsg { kind: i32, a: f32, b: f32, c: f32 }
let MSG_SIZE: i32 = 1;       // a: width, b: the view's height, c: backing scale
let MSG_HIT: i32 = 2;        // a, b: a point on the page
let MSG_SNAPSHOT: i32 = 3;   // a: the width to lay the page out at, b: the view's height
let MSG_QUIT: i32 = 4;

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
let REPLY_READ: i32 = 6;     // value: the file's size in bytes, once read

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

// What the main thread knows of a tab: its worker; what came with its last
// display list (`ready` once one has) and what taking it cost there; whether
// it failed; whether a display list waits to be taken when it is shown; how
// far it is scrolled; when it opened and how long it took to
// show; and spans of the main thread's notes: its title, why it failed, its
// elements.
struct Tab {
    worker: i64, ready: bool, failed: bool, info: FrameInfo, paint: f32, waiting: bool, scroll: f32, opened: i64,
    load_ms: f32, title_at: i64, title_len: i64, why_at: i64, why_len: i64, elems_at: i64, elems_len: i64,
}

fn ms_since(from: i64) -> f32 { return ((clock_ns() - from) / 1000000.0) as f32; }

// Tab `tab`'s worker, for the page at `path`.
thread_fn tab_worker(tab: i32, path: u8[>..]) {
    var src: u8[>..] = [];
    var t = clock_ns();
    guard read_file(path[..], src) else {
        tp_post_reply(tab, REPLY_FAILED, 0, str("can't read ", path)[..]);
        serve_nothing(tab);
        return;
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
    t = clock_ns();
    var rules: Rule[>..] = [];
    var comps: Compound[>..] = [];
    var classes: Span[>..] = [];
    var decls: Decl[>..] = [];
    var sheet_bytes: u8[>..] = [];
    var sel_attrs: AttrSel[>..] = [];
    var vars: Var[>..] = [];
    var var_bytes: u8[>..] = [];
    let sh = Sheet { rules: rules, comps: comps, classes: classes, attrs: sel_attrs, decls: decls, bytes: sheet_bytes,
                     vars: vars, var_bytes: var_bytes };
    load_sheets(d, sh);
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
    serve(tab, P, info);
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
fn serve(tab: i32, P: Page, info: FrameInfo&) {
    var items: DItem[>..<] = [];     // the display list as laid out last, for hit tests
    var bounds: f32[>..<] = [];      // where its items are: made at the first hit test after a layout
    var bounded = false;
    var paths: f32[>..<] = [];
    var m = TabMsg { kind: 0, a: 0.0, b: 0.0, c: 0.0 };
    loop {
        // A mailbox that fails (closed under it) ends the worker.
        let got = tp_tab_next(tab, -1, m);
        guard got >= 0 else { return; }
        guard got == 1 else { continue; }
        if m.kind == MSG_QUIT { return; }
        if m.kind == MSG_SIZE {
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
        } else if m.kind == MSG_SNAPSHOT {
            var out: u8[>..] = [];
            snapshot_of(P, m.a, m.b, info, out);
            tp_post_reply(tab, REPLY_SNAPSHOT, 0, out[..]);
        }
    }
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
