// Tusk's app (docs/adr/0005): opens a saved page, lays it out and scrolls it
// on the compositor (docs/adr/0003). The main thread sleeps until something
// happens; a scroll moves what is already on the GPU and nothing else, and an
// idle window draws nothing. The bar at the bottom shows the page's weight.
//
//   tusk [page.html]                     open a page (the Focaccia article by default)
//   tusk snapshot [page.html]            print the page as a tree for agents (docs/adr/0007)
//   tusk --screenshot out.png [--at Y] [--size WxH] [page.html]
//                                        draw the window offscreen into a PNG; no window opens;
//                                        --size makes its page W × H points, the bar below
//   tusk --scroll-test [page.html]       scroll the page for 10 s and print frame times
//   tusk --idle-exit MS [page.html]      quit after MS of quiet (the idle test)
//   tusk --wake-test                     a worker wakes the sleeping main thread (the M0 test)
//
// It exits 0 when done, 1 when something failed, 2 for wrong arguments, and 3
// when --screenshot finds no Metal device (a CI runner without a GPU).

import std;
import os;
import math;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.css;
import engine.layout;
import engine.snapshot;
import engine.hit;

struct Event { kind: i32, code: i32, x: f64, y: f64, w: f64, h: f64 }

// Where a layer goes (platform/src/compositor.rs, Place), in points: its
// content's point (scroll_x, scroll_y) lands on the window's (x, y), and a, b,
// c, d turn and scale it about there (all 0: none). With clip_w 0 or more it
// shows only inside its clip, measured from where it lands, its corners
// rounded by radius (at most half its shorter side); a clip with no area shows
// nothing, and clip_w below 0 is none. Opacity fades each thing in it, so
// where two overlap the one below shows through. It is drawn over the layers
// of a lower z, and only when shown isn't 0. Points are at most 1e7 from 0
// and a, b, c, d at most 1e4. Placing a layer rebuilds nothing.
struct Place {
    x: f32, y: f32, scroll_x: f32, scroll_y: f32, a: f32, b: f32, c: f32, d: f32,
    clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32, radius: f32, opacity: f32, z: i32, shown: i32,
}

struct FrameStats {
    frames: i32, dropped: i32, refresh_hz: f32,
    max_interval_ms: f32, mean_interval_ms: f32, max_cpu_ms: f32, max_gpu_ms: f32,
}

extern "tusk_platform" {
    fn tp_open(width: f64, height: f64, title: const u8&, title_len: i64) -> i32;
    fn tp_next_event(timeout_ms: i64, out: Event&) -> i32;
    fn tp_render(background: u32) -> i32;
    fn tp_start_metal() -> i32;
    fn tp_set_layer(layer: i32, items: const DItem[:], text: const u8[:], paths: const f32[:], scale: f32) -> i32;
    fn tp_place_layer(layer: i32, place: const Place&) -> i32;
    fn tp_screenshot(path: const u8[:], width: f32, height: f32, scale: f32, background: u32) -> i32;
    fn tp_frame_stats(out: FrameStats&, reset: bool) -> i32;
    fn tp_memory_footprint() -> i64;
    fn tp_frames() -> i64;
    fn tp_close() -> i32;
    fn tp_wake(token: i32) -> i32;
    fn tp_set_cursor(kind: i32) -> i32;
}

// Event kinds, as numbered in platform/src/lib.rs.
let EV_NONE: i32 = 0;
let EV_CLOSE: i32 = 1;
let EV_RESIZE: i32 = 2;
let EV_KEY: i32 = 3;
let EV_SCROLL: i32 = 5;
let EV_WAKE: i32 = 6;
let EV_MOUSE_MOVE: i32 = 8;
let EV_MOUSE_LEAVE: i32 = 9;

// Pointer shapes, as numbered in platform/src/lib.rs.
let CURSOR_ARROW: i32 = 0;
let CURSOR_POINTER: i32 = 1;

// macOS virtual key codes and modifier flags.
let KEY_Q: i32 = 12;
let KEY_W: i32 = 13;
let KEY_SPACE: i32 = 49;
let KEY_HOME: i32 = 115;
let KEY_PAGE_UP: i32 = 116;
let KEY_END: i32 = 119;
let KEY_PAGE_DOWN: i32 = 121;
let KEY_DOWN: i32 = 125;
let KEY_UP: i32 = 126;
let MOD_SHIFT: i64 = 0x20000;
let MOD_COMMAND: i64 = 0x100000;

let MODE_WINDOW: i32 = 0;
let MODE_SNAPSHOT: i32 = 1;
let MODE_SCREENSHOT: i32 = 2;
let MODE_SCROLL_TEST: i32 = 3;
let MODE_WAKE_TEST: i32 = 4;

let WINDOW_W: f32 = 960.0;
let WINDOW_H: f32 = 720.0;
let BAR_H: f32 = 26.0;           // the weight bar along the bottom
let SETTLE_MS: i64 = 5000;       // how long after a frame the bar weighs the page again
let WHEEL_LINE: f32 = 40.0;      // points one line of a mouse wheel scrolls
let LAYER_PAGE: i32 = 0;
let LAYER_BAR: i32 = 1;
let ERR_ARGUMENT: i32 = -4;      // platform/src/lib.rs
let ERR_NO_DEVICE: i32 = -5;     // platform/src/lib.rs

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

// What showing the page has cost, in milliseconds, for the bar.
struct Cost { bytes: i64, parse: f64, style: f64, measure: f64, layout: f64, paint: f64 }

fn ms(from: i64, to: i64) -> f64 { return (to - from) / 1000000.0; }

// Hands a layer to the compositor. One it refuses would leave the window or
// the screenshot without it, so Tusk stops and says why.
fn set_layer(layer: i32, items: const DItem[:], text: const u8[:], paths: const f32[:], scale: f32) {
    let rc = tp_set_layer(layer, items, text, paths, scale);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused layer ", layer, " (error ", rc, ")\n"));
    exit(1);
}

// The page's layer: scrolled by `scroll`, and shown only in its view, `width`
// × `view_h` at the window's corner, which spares the GPU the rest. A window
// shorter than the bar has no view, and the page doesn't show.
fn place_page(scroll: f32, width: f32, view_h: f32) {
    let p = Place { x: 0.0, y: 0.0, scroll_x: 0.0, scroll_y: scroll, a: 0.0, b: 0.0, c: 0.0, d: 0.0,
                    clip_x: 0.0, clip_y: 0.0, clip_w: max(width, 0.0), clip_h: max(view_h, 0.0),
                    radius: 0.0, opacity: 1.0, z: 0, shown: 1 };
    let rc = tp_place_layer(LAYER_PAGE, p);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused the page's place (error ", rc, ")\n"));
    exit(1);
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

// Lays the page out `width` points wide, for a view `view_h` points high, and
// hands the display list to the compositor; `items` keeps it, for what is
// under the pointer. Returns the page's height.
fn show_page(P: Page, items: DItem[>..<]&, width: f32, view_h: f32, scale: f32, cost: Cost&) -> f32 {
    var boxes: Rect[>..] = [];
    items.resize(0);
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
    let height = layout_page(L, width, view_h);
    let t1 = clock_ns();
    set_layer(LAYER_PAGE, items, P.text, paths, scale);
    cost.layout = ms(t0, t1);
    cost.paint = ms(t1, clock_ns());
    return height;
}

// What the page weighs and what each stage of showing it took.
fn weight(P: Page, name: const u8[:], cost: Cost, line: u8[>..]&) {
    format(line, name, "  ");
    group(line, (cost.bytes + 500) / 1000);
    line.append(" KB · ");
    group(line, P.d.nodes.len);
    line.append(" nodes · parse ");
    format_flt(line, cost.parse, 1);
    line.append(" · style ");
    format_flt(line, cost.style, 1);
    line.append(" · text ");
    format_flt(line, cost.measure, 1);
    line.append(" · layout ");
    format_flt(line, cost.layout, 1);
    line.append(" · paint ");
    format_flt(line, cost.paint, 1);
    line.append(" ms · ");
    format_flt(line, tp_memory_footprint() / 1048576.0, 1);
    line.append(" MB");
}

// The bar along the bottom of the window, with the page's weight.
fn show_bar(P: Page, name: const u8[:], cost: Cost, width: f32, height: f32, scale: f32) {
    var line: u8[>..] = [];
    weight(P, name, cost, line);
    var items: DItem[>..] = [];
    items.push(rect_item(-1, 0.0, height - BAR_H, width, BAR_H, 0xFF1B1C1E));
    items.push(text_item(-1, 12.0, height - 9.5, 0.0, 0xFFC9CBCF, FAMILY_MONO, 11.0, 0, line.len as i32));
    set_layer(LAYER_BAR, items, line, [], scale);
}

// n with its thousands separated by commas.
recursive fn group(out: u8[>..]&, n: i64) {
    if n >= 1000 {
        group(out, n / 1000);
        out.push(',');
        format_int(out, n % 1000, 10, 3, '0');
    } else {
        format(out, n);
    }
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

fn clamp_scroll(y: f32, page_h: f32, view_h: f32) -> f32 {
    return max(min(y, page_h - view_h), 0.0);
}

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame will take.
thread_fn wake_after(ms: i64, token: i32) {
    sleep_ms(ms);
    tp_wake(token);
}

fn usage() {
    write_stderr("usage: tusk [snapshot | --screenshot out.png [--at Y] [--size WxH] | --scroll-test | --idle-exit MS | --wake-test] [page.html]\n");
    exit(2);
}

fn main() {
    var mode = MODE_WINDOW;
    var path: u8[>..] = [];
    var shot: u8[>..] = [];
    var at: f32 = 0.0;
    var has_at = false;
    var shot_w = WINDOW_W;           // --size: the page's view in a screenshot, the bar below it
    var shot_h = WINDOW_H - BAR_H;
    var has_size = false;
    var idle_exit_ms: i64 = -1;
    let argv = args();
    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        let valued = i + 1 < argv.len;
        if a == "snapshot" || a == "--scroll-test" || a == "--wake-test" || (a == "--screenshot" && valued) {
            guard mode == MODE_WINDOW else { usage(); return; }   // one mode a run
            if a == "snapshot" { mode = MODE_SNAPSHOT; }
            else if a == "--scroll-test" { mode = MODE_SCROLL_TEST; }
            else if a == "--wake-test" { mode = MODE_WAKE_TEST; idle_exit_ms = 5000; }
            else { mode = MODE_SCREENSHOT; i += 1; shot.append(argv[i]); }
        } else if a == "--at" && valued {
            i += 1;
            let n, ok = parse_flt(argv[i]);
            guard ok else { usage(); return; }
            at = n as f32;
            has_at = true;
        } else if a == "--size" && valued {
            i += 1;
            let x = find(argv[i], "x");
            guard x > 0 else { usage(); return; }
            let w, wok = parse_int(argv[i][..x]);
            let h, hok = parse_int(argv[i][x + 1..]);
            guard wok && hok && w >= 100 && w <= 4000 && h >= 100 && h <= 4000 else { usage(); return; }
            shot_w = w;
            shot_h = h;
            has_size = true;
        } else if a == "--idle-exit" && valued {
            i += 1;
            let n, ok = parse_int(argv[i]);
            guard ok && n >= 0 else { usage(); return; }
            idle_exit_ms = n;
        }
        else if path.len == 0 && a.len > 0 && a[0] != '-' { path.append(a); }
        else { usage(); return; }
        i += 1;
    }
    guard (!has_at && !has_size) || mode == MODE_SCREENSHOT else { usage(); return; }
    if path.len == 0 { path.append(str(resource_dir(), "../tests/pages/focaccia.html")); }
    // The fonts Tusk brings (Barlow Condensed, JetBrains Mono), before any text is measured.
    tp_register_fonts(str(resource_dir(), "fonts")[..]);
    var name_start: i64 = 0;
    for ch, k in path { if ch == '/' { name_start = k + 1; } }

    var src: u8[>..] = [];
    guard read_file(path[..], src) else {
        write_stderr(str("tusk: can't read ", path, "\n"));
        exit(1);
        return;
    }
    var cost = Cost { bytes: src.len, parse: 0.0, style: 0.0, measure: 0.0, layout: 0.0, paint: 0.0 };
    let t0 = clock_ns();
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(src[..], d);
    let t1 = clock_ns();
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
    let t2 = clock_ns();
    var text: u8[>..] = [];
    var carets: f32[>..] = [];
    var runs: Run[>..] = [];
    var run_of: i32[>..] = [];
    var fonts: FontInfo[>..] = [];
    let P = Page { d: d, styles: styles, text: text, carets: carets, runs: runs, run_of: run_of, fonts: fonts };
    measure_page(P);
    let t3 = clock_ns();
    cost.parse = ms(t0, t1);
    cost.style = ms(t1, t2);
    cost.measure = ms(t2, t3);
    let bg = background_of(P);

    if mode == MODE_SNAPSHOT {
        print_snapshot(P, cost, src.len);
        return;
    }
    if mode == MODE_SCREENSHOT {
        // Metal is set up before the page is timed, as tp_open does for the
        // window, so paint is the page's cost and not the setup's.
        let metal = tp_start_metal();
        guard metal == 0 else {
            if metal == ERR_NO_DEVICE {
                write_stderr("tusk: no screenshot: there is no Metal device\n");
                exit(3);
            }
            write_stderr(str("tusk: no screenshot: Metal didn't start (error ", metal, ")\n"));
            exit(1);
            return;
        }
        let scale: f32 = 2.0;
        var items: DItem[>..<] = [];
        let page_h = show_page(P, items, shot_w, shot_h, scale, cost);
        show_bar(P, path[name_start..], cost, shot_w, shot_h + BAR_H, scale);
        let y = clamp_scroll(at, page_h, shot_h);
        place_page(y, shot_w, shot_h);
        let rc = tp_screenshot(shot, shot_w, shot_h + BAR_H, scale, bg);
        guard rc == 0 else {
            if rc == ERR_ARGUMENT {
                write_stderr("tusk: no screenshot: the file can't be written\n");
            } else {
                write_stderr(str("tusk: no screenshot: drawing it failed (error ", rc, ")\n"));
            }
            exit(1);
            return;
        }
        print("wrote ", shot, ": the window at 2x, scrolled to ", y, " of a page ", page_h, " points tall");
        return;
    }

    var title: u8[>..] = [];
    for n, k in nodes {
        if n.kind == NODE_ELEMENT && n.first >= 0 && node_name(d, k as i32) == "title" {
            title.append(node_text(d, n.first));
            break;
        }
    }
    if title.len == 0 { title.append("Tusk"); }
    guard tp_open(WINDOW_W, WINDOW_H, title[0], title.len) == 0 else {
        write_stderr("tusk: could not open a window\n");
        exit(1);
        return;
    }

    var worker: i64 = -1;
    if mode == MODE_WAKE_TEST { worker = thread_spawn_contained(wake_after, 300, 42); }

    var width: f32 = 0.0;
    var height: f32 = 0.0;
    var scale: f32 = 0.0;
    var page_h: f32 = 0.0;
    var scroll: f32 = 0.0;
    var settle = false;      // a frame has been drawn since the bar last weighed the page
    var woken = false;
    var items: DItem[>..<] = [];   // the page's display list as laid out last
    var pointer_x: f32 = -1.0;     // where the pointer is over the content, or -1 off it
    var pointer_y: f32 = -1.0;
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var quit = false;
    while !quit {
        // Drawing allocates memory the system only settles later, so a while
        // after the last frame the bar weighs the page again, once.
        let wait = if idle_exit_ms >= 0 { idle_exit_ms } else if settle { SETTLE_MS } else { -1 };
        guard tp_next_event(wait, e) == 0 else {
            write_stderr("tusk: the window's events failed\n");
            exit(1);
            return;
        }
        if e.kind == EV_NONE {
            guard idle_exit_ms < 0 else { break; }
            settle = false;
            show_bar(P, path[name_start..], cost, width, height, scale);
            tp_render(bg);
            continue;
        }
        // This event and every one already waiting, then at most one frame.
        let before = scroll;
        var relayout = false;
        var resized = false;
        var moved = false;
        loop {
            if e.kind == EV_CLOSE { quit = true; }
            else if e.kind == EV_RESIZE {
                let w = e.w as f32;
                let s = e.x as f32;
                if w != width || s != scale { relayout = true; }
                width = w;
                height = e.h as f32;
                scale = s;
                resized = true;
            } else if e.kind == EV_SCROLL {
                let dy = e.y as f32;
                scroll -= if e.code == 1 { dy } else { dy * WHEEL_LINE };
                pointer_x = e.w as f32;
                pointer_y = e.h as f32;
                moved = true;
            } else if e.kind == EV_MOUSE_MOVE {
                pointer_x = e.x as f32;
                pointer_y = e.y as f32;
                moved = true;
            } else if e.kind == EV_MOUSE_LEAVE {
                pointer_x = -1.0;
                pointer_y = -1.0;
            } else if e.kind == EV_KEY {
                let mods = e.x as i64;
                let page = height - BAR_H - 40.0;
                if (mods & MOD_COMMAND) != 0 && (e.code == KEY_Q || e.code == KEY_W) { quit = true; }
                else if e.code == KEY_SPACE { scroll += if (mods & MOD_SHIFT) != 0 { -page } else { page }; }
                else if e.code == KEY_PAGE_DOWN { scroll += page; }
                else if e.code == KEY_PAGE_UP { scroll -= page; }
                else if e.code == KEY_DOWN { scroll += WHEEL_LINE; }
                else if e.code == KEY_UP { scroll -= WHEEL_LINE; }
                else if e.code == KEY_HOME { scroll = 0.0; }
                else if e.code == KEY_END { scroll = page_h; }
            } else if e.kind == EV_WAKE {
                print("woken by a worker, token ", e.code);
                woken = true;
                if mode == MODE_WAKE_TEST { quit = true; }
            }
            guard tp_next_event(0, e) == 0 && e.kind != EV_NONE else { break; }
        }
        if quit { break; }
        if relayout { page_h = show_page(P, items, width, height - BAR_H, scale, cost); }
        // The bar sits at the window's bottom edge: it moves with any resize.
        if resized { show_bar(P, path[name_start..], cost, width, height, scale); }
        scroll = clamp_scroll(scroll, page_h, height - BAR_H);
        // A frame only when what is on screen changed.
        if resized || scroll != before {
            place_page(scroll, width, height - BAR_H);
            tp_render(bg);
            settle = true;
        }
        // Over a link the pointer is a hand. What is under it changes when it
        // moves, and when the page moves under it.
        if (moved || relayout || scroll != before) && pointer_y >= 0.0 && pointer_y < height - BAR_H {
            let link = link_at(d, node_at(items[..], fonts[..], pointer_x, pointer_y + scroll));
            tp_set_cursor(if link >= 0 { CURSOR_POINTER } else { CURSOR_ARROW });
        }
        if mode == MODE_SCROLL_TEST {
            scroll_test(page_h, width, height, bg);
            quit = true;
        }
    }
    let worker_ok = worker < 0 || thread_wait(worker);
    var line: u8[>..] = [];
    weight(P, path[name_start..], cost, line);
    print(line);
    print("frames presented: ", tp_frames());
    tp_close();
    if mode == MODE_WAKE_TEST && !(woken && worker_ok) {
        write_stderr("tusk: the worker's wake never arrived\n");
        exit(1);
    }
}

// `tusk snapshot`: the page as a tree on stdout, and what it cost on stderr.
fn print_snapshot(P: Page, cost: Cost, html_bytes: i64) {
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
    let h = layout_page(L, WINDOW_W, WINDOW_H - BAR_H);
    let t1 = clock_ns();
    var out: u8[>..] = [];
    let entries = snapshot(L, WINDOW_W, h, out);
    let t2 = clock_ns();
    write_stdout(out);
    var note: u8[>..] = [];
    format(note, "snapshot: ", entries, " entries, ");
    format_flt(note, out.len / 1000.0, 1);
    format(note, " KB from ", (html_bytes + 500) / 1000, " KB of HTML; parse ");
    format_flt(note, cost.parse, 1);
    note.append(" + style ");
    format_flt(note, cost.style, 1);
    note.append(" + text ");
    format_flt(note, cost.measure, 1);
    note.append(" + layout ");
    format_flt(note, ms(t0, t1), 1);
    note.append(" + tree ");
    format_flt(note, ms(t1, t2), 1);
    note.append(" ms\n");
    write_stderr(note);
}

// Scrolls down the page and back for 10 s at a brisk flick's speed, a frame
// per display refresh, and prints what the frames cost (docs/adr/0003).
fn scroll_test(page_h: f32, width: f32, height: f32, bg: u32) {
    var stats = FrameStats { frames: 0, dropped: 0, refresh_hz: 0.0, max_interval_ms: 0.0, mean_interval_ms: 0.0,
                             max_cpu_ms: 0.0, max_gpu_ms: 0.0 };
    tp_frame_stats(stats, true);
    let travel = max(page_h - (height - BAR_H), 1.0);
    let speed: f32 = 2000.0;       // points per second
    let start = clock_ns();
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    loop {
        // Keep AppKit's queue moving, as a real session would.
        while tp_next_event(0, e) == 0 && e.kind != EV_NONE {
            if e.kind == EV_CLOSE { return; }
            if e.kind == EV_KEY && ((e.x as i64) & MOD_COMMAND) != 0 && e.code == KEY_Q { return; }
        }
        let t = ms(start, clock_ns()) / 1000.0;
        if t >= 10.0 { break; }
        let d = speed * t;
        let laps = floor(d / (2.0 * travel));
        let p = d - laps * 2.0 * travel;
        place_page((if p < travel { p } else { 2.0 * travel - p }) as f32, width, height - BAR_H);
        tp_render(bg);
    }
    tp_frame_stats(stats, false);
    print("scroll test: ", stats.frames, " frames in 10 s at ", stats.refresh_hz, " Hz; dropped ", stats.dropped,
          "; frame interval mean ", stats.mean_interval_ms, " ms, max ", stats.max_interval_ms,
          " ms; per frame CPU max ", stats.max_cpu_ms, " ms, GPU max ", stats.max_gpu_ms, " ms; memory ",
          tp_memory_footprint() / 1048576, " MB");
}
