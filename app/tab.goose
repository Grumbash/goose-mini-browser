// A tab's page (docs/adr/0010). Each runs in a contained worker that owns its
// document, so a page that fails ends its tab only, and the main thread never
// lays a page out. The worker loads, parses, styles and measures the page,
// then lays it out for each size the main thread posts, and hands the display
// list over in one copy (platform/src/tabs.rs). It answers hit tests and
// snapshot requests from the list as laid out last.

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
// size in nodes and bytes, what each stage took in milliseconds, and the
// backing scale it is for.
struct FrameInfo {
    height: f32, background: u32, nodes: i32, bytes: i32,
    parse: f32, style: f32, measure: f32, layout: f32, scale: f32,
}

// A reply's kind, number and length of text.
struct ReplyHead { kind: i32, value: i32, len: i64 }
let REPLY_HIT: i32 = 1;      // value: the pointer shape over the point
let REPLY_TITLE: i32 = 2;    // text: the page's title
let REPLY_SNAPSHOT: i32 = 3; // text: the page as a tree for agents
let REPLY_FAILED: i32 = 4;   // text: why the page didn't load

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

fn ms_since(from: i64) -> f32 { return ((clock_ns() - from) / 1000000.0) as f32; }

// Tab `tab`'s worker, for the page at `path`.
thread_fn tab_worker(tab: i32, path: u8[>..]) {
    var src: u8[>..] = [];
    guard read_file(path[..], src) else {
        tp_post_reply(tab, REPLY_FAILED, 0, str("can't read ", path)[..]);
        serve_nothing(tab);
        return;
    }
    var info = FrameInfo { height: 0.0, background: 0xFFFFFFFF, nodes: 0, bytes: src.len as i32,
                           parse: 0.0, style: 0.0, measure: 0.0, layout: 0.0, scale: 1.0 };
    var t = clock_ns();
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
            title.append(node_text(d, n.first));
            break;
        }
    }
    tp_post_reply(tab, REPLY_TITLE, 0, title[..]);
    serve(tab, P, info);
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
