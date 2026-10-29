// Tusk's app (docs/adr/0005): opens a saved page, lays it out and scrolls it
// on the compositor (docs/adr/0003). The main thread sleeps until something
// happens; a scroll moves what is already on the GPU and nothing else, and an
// idle window draws nothing. The bar at the bottom shows the page's weight.
//
//   tusk [page.html]                     open a page (the Focaccia article by default)
//   tusk --screenshot out.png [--at Y] [page.html]
//                                        draw the window offscreen into a PNG; no window opens
//   tusk --scroll-test [page.html]       scroll the page for 10 s and print frame times
//   tusk --idle-exit MS [page.html]      quit after MS of quiet (the idle test)
//   tusk --wake-test                     a worker wakes the sleeping main thread (the M0 test)

import std;
import os;
import math;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.css;
import engine.layout;

struct Event { kind: i32, code: i32, x: f64, y: f64, w: f64, h: f64 }

struct FrameStats {
    frames: i32, dropped: i32, refresh_hz: f32,
    max_interval_ms: f32, mean_interval_ms: f32, max_cpu_ms: f32, max_gpu_ms: f32,
}

extern "tusk_platform" {
    fn tp_open(width: f64, height: f64, title: const u8&, title_len: i64) -> i32;
    fn tp_next_event(timeout_ms: i64, out: Event&) -> i32;
    fn tp_render(scroll: f32, background: u32) -> i32;
    fn tp_set_layer(layer: i32, items: const DItem[:], text: const u8[:], scale: f32) -> i32;
    fn tp_screenshot(path: const u8[:], width: f32, height: f32, scale: f32, scroll: f32, background: u32) -> i32;
    fn tp_frame_stats(out: FrameStats&, reset: bool) -> i32;
    fn tp_memory_footprint() -> i64;
    fn tp_frames() -> i64;
    fn tp_close() -> i32;
    fn tp_wake(token: i64) -> i32;
}

// Event kinds, as numbered in platform/src/lib.rs.
let EV_NONE: i32 = 0;
let EV_CLOSE: i32 = 1;
let EV_RESIZE: i32 = 2;
let EV_KEY: i32 = 3;
let EV_SCROLL: i32 = 5;
let EV_WAKE: i32 = 6;

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
let MODE_SCREENSHOT: i32 = 2;
let MODE_SCROLL_TEST: i32 = 3;
let MODE_WAKE_TEST: i32 = 4;

let WINDOW_W: f32 = 960.0;
let WINDOW_H: f32 = 720.0;
let BAR_H: f32 = 26.0;           // the weight bar along the bottom
let WHEEL_LINE: f32 = 40.0;      // points one line of a mouse wheel scrolls
let LAYER_PAGE: i32 = 0;
let LAYER_BAR: i32 = 1;

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

fn measure_page(P: Page) {
    var boxes: Rect[>..] = [];
    var items: DItem[>..] = [];
    let L = Layout { d: P.d, styles: P.styles, text: P.text, carets: P.carets, runs: P.runs, run_of: P.run_of,
                     fonts: P.fonts, boxes: boxes, items: items };
    measure(L);
}

// Lays the page out `width` points wide and hands the display list to the
// compositor. Returns the page's height.
fn show_page(P: Page, width: f32, scale: f32, cost: Cost&) -> f32 {
    var boxes: Rect[>..] = [];
    var items: DItem[>..] = [];
    let L = Layout { d: P.d, styles: P.styles, text: P.text, carets: P.carets, runs: P.runs, run_of: P.run_of,
                     fonts: P.fonts, boxes: boxes, items: items };
    let t0 = clock_ns();
    let height = layout_page(L, width);
    let t1 = clock_ns();
    tp_set_layer(LAYER_PAGE, items, P.text, scale);
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
    items.push(DItem { kind: ITEM_RECT, x: 0.0, y: height - BAR_H, w: width, h: BAR_H, color: 0xFF1B1C1E,
                       font: 0, size: 0.0, text: 0, text_len: 0, node: -1 });
    items.push(DItem { kind: ITEM_TEXT, x: 12.0, y: height - 9.5, w: 0.0, h: 0.0, color: 0xFFC9CBCF,
                       font: FAMILY_MONO, size: 11.0, text: 0, text_len: line.len as i32, node: -1 });
    tp_set_layer(LAYER_BAR, items, line, scale);
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

// The canvas takes the root element's background (CSS 2.2 §14.2), white if none.
fn background_of(P: Page) -> u32 {
    let html = P.d.nodes[0].first;
    guard html >= 0 && (P.styles[html].bg >> 24) != 0 else { return 0xFFFFFFFF; }
    return P.styles[html].bg;
}

fn clamp_scroll(y: f32, page_h: f32, view_h: f32) -> f32 {
    return max(min(y, page_h - view_h), 0.0);
}

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame will take.
thread_fn wake_after(ms: i64, token: i64) {
    sleep_ms(ms);
    tp_wake(token);
}

fn usage() {
    write_stderr("usage: tusk [--screenshot out.png [--at Y] | --scroll-test | --idle-exit MS | --wake-test] [page.html]\n");
    exit(2);
}

fn main() {
    var mode = MODE_WINDOW;
    var path: u8[>..] = [];
    var shot: u8[>..] = [];
    var at: f32 = 0.0;
    var idle_exit_ms: i64 = -1;
    let argv = args();
    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--scroll-test" { mode = MODE_SCROLL_TEST; }
        else if a == "--wake-test" { mode = MODE_WAKE_TEST; idle_exit_ms = 5000; }
        else if (a == "--screenshot" || a == "--at" || a == "--idle-exit") && i + 1 < argv.len {
            i += 1;
            if a == "--screenshot" { mode = MODE_SCREENSHOT; shot.append(argv[i]); }
            else {
                let n, ok = parse_int(argv[i]);
                guard ok else { usage(); return; }
                if a == "--at" { at = n; } else { idle_exit_ms = n; }
            }
        }
        else if path.len == 0 && a.len > 0 && a[0] != '-' { path.append(a); }
        else { usage(); return; }
        i += 1;
    }
    if path.len == 0 { path.append(str(resource_dir(), "../tests/pages/focaccia.html")); }
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
    let sh = Sheet { rules: rules, comps: comps, classes: classes, decls: decls, bytes: sheet_bytes };
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

    if mode == MODE_SCREENSHOT {
        let scale: f32 = 2.0;
        let page_h = show_page(P, WINDOW_W, scale, cost);
        show_bar(P, path[name_start..], cost, WINDOW_W, WINDOW_H, scale);
        let y = clamp_scroll(at, page_h, WINDOW_H - BAR_H);
        guard tp_screenshot(shot, WINDOW_W, WINDOW_H, scale, y, bg) == 0 else {
            write_stderr("tusk: no screenshot (no Metal device, or the file can't be written)\n");
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
    var weighed = false;     // the bar's memory figure includes the first frame
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var quit = false;
    while !quit {
        guard tp_next_event(idle_exit_ms, e) == 0 else { break; }
        if e.kind == EV_NONE { break; }      // only with --idle-exit
        // This event and every one already waiting, then one frame.
        var relayout = false;
        var redraw = false;
        loop {
            if e.kind == EV_CLOSE { quit = true; }
            else if e.kind == EV_RESIZE {
                let w = e.w as f32;
                let s = e.x as f32;
                if w != width || s != scale { relayout = true; }
                width = w;
                height = e.h as f32;
                scale = s;
                redraw = true;
            } else if e.kind == EV_SCROLL {
                let dy = e.y as f32;
                scroll -= if e.code == 1 { dy } else { dy * WHEEL_LINE };
                redraw = true;
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
                redraw = true;
            } else if e.kind == EV_WAKE {
                print("woken by a worker, token ", e.code);
                if mode == MODE_WAKE_TEST { quit = true; }
            }
            guard tp_next_event(0, e) == 0 && e.kind != EV_NONE else { break; }
        }
        if quit { break; }
        if relayout {
            page_h = show_page(P, width, scale, cost);
            show_bar(P, path[name_start..], cost, width, height, scale);
        }
        scroll = clamp_scroll(scroll, page_h, height - BAR_H);
        if redraw { tp_render(scroll, bg); }
        if !weighed && tp_frames() > 0 {
            // The first frame allocated the window's drawables: weigh again.
            weighed = true;
            show_bar(P, path[name_start..], cost, width, height, scale);
            tp_render(scroll, bg);
        }
        if mode == MODE_SCROLL_TEST {
            scroll_test(page_h, height, bg);
            quit = true;
        }
    }
    if worker >= 0 { thread_wait(worker); }
    var line: u8[>..] = [];
    weight(P, path[name_start..], cost, line);
    print(line);
    print("frames presented: ", tp_frames());
    tp_close();
}

// Scrolls down the page and back for 10 s at a brisk flick's speed, a frame
// per display refresh, and prints what the frames cost (docs/adr/0003).
fn scroll_test(page_h: f32, height: f32, bg: u32) {
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
        }
        let t = ms(start, clock_ns()) / 1000.0;
        if t >= 10.0 { break; }
        let d = speed * t;
        let laps = floor(d / (2.0 * travel));
        let p = d - laps * 2.0 * travel;
        tp_render((if p < travel { p } else { 2.0 * travel - p }) as f32, bg);
    }
    tp_frame_stats(stats, false);
    print("scroll test: ", stats.frames, " frames in 10 s at ", stats.refresh_hz, " Hz; dropped ", stats.dropped,
          "; frame interval mean ", stats.mean_interval_ms, " ms, max ", stats.max_interval_ms,
          " ms; per frame CPU max ", stats.max_cpu_ms, " ms, GPU max ", stats.max_gpu_ms, " ms; memory ",
          tp_memory_footprint() / 1048576, " MB");
}
