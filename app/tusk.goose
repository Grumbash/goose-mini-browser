// Tusk's app (docs/adr/0005, 0010): opens saved pages, each in a tab whose
// worker loads and lays it out (tab.goose), and shows them in its interface
// (ui.goose): a document laid out here, on the main thread, when what it shows
// changes, with the page in focus drawn where it marks its slot (docs/adr/0003).
// The main thread owns the window and the compositor and lays no page out. It
// sleeps until something happens; a scroll moves what is already on the GPU
// and nothing else, and an idle window draws nothing.
//
//   tusk [page.html ...]                 open pages, one tab each (the Focaccia article by default);
//                                        ⌘1 to ⌘9 show a tab, ⌘⌥I hides the dev panel
//   tusk snapshot [page.html]            print the page as a tree for agents (docs/adr/0007)
//   tusk --screenshot out.png [--at Y] [--size WxH] [--dev-tab NAME] [--bare] [page.html]
//                                        draw the window offscreen into a PNG, W × H points
//                                        (1200 × 760 unless given); no window opens. --bare
//                                        draws the page alone, the interface left out, to
//                                        check the engine; --dev-tab shows the dev panel's
//                                        console, network, elements, frames or oil, or
//                                        off, the panel hidden as ⌘⌥I hides it
//   tusk --scroll-test [page.html]       scroll the page for 10 s and print frame times
//   tusk --idle-exit MS [page.html ...]  quit after MS of quiet (the idle test)
//   tusk --wake-test                     a worker wakes the sleeping main thread (the M0 test)
//
// It exits 0 when done, 1 when something failed, 2 for wrong arguments, and 3
// when --screenshot finds no Metal device (a CI runner without a GPU).

import std;
import os;
import math;
import engine from "../engine";
import engine.dom;
import engine.css;
import engine.layout;
import .tab;
import .ui;

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
    fn tp_open(width: f64, height: f64, bar: f64, lights_x: f64, title: const u8&, title_len: i64) -> i32;
    fn tp_set_drag_regions(drag: const f32[:], holes: const f32[:]) -> i32;
    fn tp_lights_end() -> f64;
    fn tp_next_event(timeout_ms: i64, out: Event&) -> i32;
    fn tp_render(background: u32) -> i32;
    fn tp_start_metal() -> i32;
    fn tp_place_layer(layer: i32, place: const Place&) -> i32;
    fn tp_drop_layer(layer: i32) -> i32;
    fn tp_screenshot(path: const u8[:], width: f32, height: f32, scale: f32, background: u32) -> i32;
    fn tp_frame_stats(out: FrameStats&, reset: bool) -> i32;
    fn tp_frame_times(out: f32[:]) -> i64;
    fn tp_memory_footprint() -> i64;
    fn tp_cpu_ns() -> i64;
    fn tp_frames() -> i64;
    fn tp_close() -> i32;
    fn tp_wake(token: i32) -> i32;
    fn tp_set_cursor(kind: i32) -> i32;
    fn tp_set_title(title: const u8[:]) -> i32;
    fn tp_text_cache(limit_bytes: i64) -> i32;
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
let EV_FRAME: i32 = 10;          // code: a tab whose display list waits
let EV_REPLY: i32 = 11;          // code: a tab whose reply waits

// macOS virtual key codes and modifier flags.
let KEY_Q: i32 = 12;
let KEY_W: i32 = 13;
let KEY_I: i32 = 34;
let KEY_SPACE: i32 = 49;
let KEY_HOME: i32 = 115;
let KEY_PAGE_UP: i32 = 116;
let KEY_END: i32 = 119;
let KEY_PAGE_DOWN: i32 = 121;
let KEY_DOWN: i32 = 125;
let KEY_UP: i32 = 126;
let KEY_DIGITS: i32[9] = [18, 19, 20, 21, 23, 22, 26, 28, 25];   // 1 to 9
let MOD_SHIFT: i64 = 0x20000;
let MOD_OPTION: i64 = 0x80000;
let MOD_COMMAND: i64 = 0x100000;

let MODE_WINDOW: i32 = 0;
let MODE_SNAPSHOT: i32 = 1;
let MODE_SCREENSHOT: i32 = 2;
let MODE_SCROLL_TEST: i32 = 3;
let MODE_WAKE_TEST: i32 = 4;

let WINDOW_W: f32 = 1200.0;      // the design's window
let WINDOW_H: f32 = 760.0;
let SNAPSHOT_W: f32 = 960.0;     // what a snapshot lays the page out at
let SNAPSHOT_H: f32 = 694.0;
let STEEL: u32 = 0xFF1D1F22;     // the window's colour under the interface
let LIGHTS_X: f32 = 14.0;        // where the traffic lights start in the bar, as the design has them
let SETTLE_MS: i64 = 5000;       // how long after a frame the oil is weighed again
let TICK_MS: i64 = 500;          // how often the window's line is measured while frames come
let RUN_AFTER_MS: i64 = 400;     // a load longer than this sends the boar running
let STEP_MS: i64 = 33;           // his steps, about 30 a second
let WHEEL_LINE: f32 = 40.0;      // points one line of a mouse wheel scrolls
let MAX_TABS: i64 = 60;          // tab k draws in layer k
let LAYER_UI: i32 = 61;          // the interface, under the pages
let LAYER_LOADER: i32 = 62;      // the boar on his rail, over them
let LOAD_WAIT_MS: i64 = 60000;   // how long the modes without a window wait for a page
let SHAPE_CACHE: i64 = 4 << 20;  // the interface's shaped text kept, in bytes
let ERR_ARGUMENT: i32 = -4;      // platform/src/lib.rs
let ERR_NO_DEVICE: i32 = -5;     // platform/src/lib.rs

fn ms(from: i64, to: i64) -> f64 { return (to - from) / 1000000.0; }

fn place(layer: i32, p: Place) {
    let rc = tp_place_layer(layer, p);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused layer ", layer, "'s place (error ", rc, ")\n"));
    exit(1);
}

// Tab k's layer: scrolled by `scroll`, landing on its slot and shown (or not)
// only there, which spares the GPU the rest of the page.
fn place_tab(k: i64, shown: bool, scroll: f32, slot: Rect) {
    place(k as i32, Place { x: slot.x, y: slot.y, scroll_x: 0.0, scroll_y: scroll, a: 0.0, b: 0.0, c: 0.0, d: 0.0,
                            clip_x: 0.0, clip_y: 0.0, clip_w: max(slot.w, 0.0), clip_h: max(slot.h, 0.0), radius: 0.0,
                            opacity: 1.0, z: 1, shown: if shown { 1 } else { 0 } });
}

// A layer at the window's corner at `y`, unclipped, at `z`.
fn place_at(layer: i32, y: f32, z: i32) {
    place(layer, Place { x: 0.0, y: y, scroll_x: 0.0, scroll_y: 0.0, a: 0.0, b: 0.0, c: 0.0, d: 0.0,
                         clip_x: 0.0, clip_y: 0.0, clip_w: -1.0, clip_h: 0.0, radius: 0.0, opacity: 1.0, z: z, shown: 1 });
}

// Takes tab k's waiting display list into its layer; true if one waited.
fn take_frame(tabs: Tab[>..]&, k: i64) -> bool {
    let t0 = clock_ns();
    let got = tp_take_frame(k as i32, k as i32, tabs[k].info);
    guard got >= 0 else {
        write_stderr(str("tusk: the compositor refused tab ", k, "'s page (error ", got, ")\n"));
        exit(1);
        return false;
    }
    guard got == 1 else { return false; }
    tabs[k].paint = ms(t0, clock_ns()) as f32;
    if !tabs[k].ready { tabs[k].load_ms = ms_since(tabs[k].opened); }
    tabs[k].ready = true;
    return true;
}

// Reads tab k's waiting replies into its state; true if one changes what the
// interface shows. A hit's pointer shape goes to `cursor` (-1: none came).
fn read_replies(tabs: Tab[>..]&, k: i64, notes: u8[>..]&, head: ReplyHead&, text: u8[>..<]&, cursor: i32&) -> bool {
    var changed = false;
    while take_reply(k, head, text) {
        if head.kind == REPLY_HIT { cursor = head.value; continue; }
        changed = true;
        if head.kind == REPLY_TITLE {
            tabs[k].title_at = notes.len;
            tabs[k].title_len = text.len;
        } else if head.kind == REPLY_ELEMENTS {
            tabs[k].elems_at = notes.len;
            tabs[k].elems_len = text.len;
        } else if head.kind == REPLY_FAILED {
            write_stderr(str("tusk: ", text, "\n"));
            tabs[k].failed = true;
            tabs[k].load_ms = ms_since(tabs[k].opened);
            tabs[k].why_at = notes.len;
            tabs[k].why_len = text.len;
            // "Can't read…", as a sentence.
            notes.append(text);
            if text.len > 0 && text[0] >= 'a' && text[0] <= 'z' { notes[tabs[k].why_at] = text[0] - 32; }
            continue;
        } else {
            continue;
        }
        notes.append(text);
    }
    return changed;
}

fn clamp_scroll(y: f32, page_h: f32, view_h: f32) -> f32 {
    return max(min(y, page_h - view_h), 0.0);
}

fn post(tab: i64, kind: i32, a: f32, b: f32, c: f32) {
    let m = TabMsg { kind: kind, a: a, b: b, c: c };
    tp_tab_post(tab as i32, m);
}

// Takes tab k's next waiting reply: its head into `head` and its text into
// `text`. False when none waits.
fn take_reply(k: i64, head: ReplyHead&, text: u8[>..<]&) -> bool {
    guard tp_reply_head(k as i32, head) == 1 else { return false; }
    text.resize(0);
    for i in head.len { text.push(0); }
    return tp_take_reply(k as i32, head, text[..]) == 0;
}

// Waits, without a window, for tab 0's display list, reading its replies
// meanwhile; stops Tusk if the page fails or never comes.
fn wait_for_frame(tabs: Tab[>..]&, notes: u8[>..]&) {
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
    var cursor: i32 = -1;
    loop {
        let got = tp_wait_tab(0, LOAD_WAIT_MS);
        guard got == 1 || got == 2 else {
            write_stderr("tusk: the page didn't come\n");
            exit(1);
            return;
        }
        if got == 1 && take_frame(tabs, 0) {
            // Its title and elements came before it.
            read_replies(tabs, 0, notes, head, text, cursor);
            return;
        }
        read_replies(tabs, 0, notes, head, text, cursor);
        guard !tabs[0].failed else { exit(1); return; }
    }
}

// The interface for what Tusk shows now, into its layer; its slot into
// `slot`. Returns what laying it out took, in ms.
fn show_ui(F: UiFiles, U: Ui, tabs: const Tab[:], T: UiText, last_ms: f32, scale: f32, slot: Rect&) -> f32 {
    var times: f32[>..<] = [];
    for i in 56 { times.push(0.0); }
    var n = tp_frame_times(times[..]);
    if n < 0 { n = 0; }
    var stats = FrameStats { frames: 0, dropped: 0, refresh_hz: 0.0, max_interval_ms: 0.0, mean_interval_ms: 0.0,
                             max_cpu_ms: 0.0, max_gpu_ms: 0.0 };
    tp_frame_stats(stats, false);
    var html: u8[>..] = [];
    ui_html(F, U, tabs, T, times[..n], stats.dropped, last_ms, html);
    var drag: f32[>..<] = [];
    var holes: f32[>..<] = [];
    let took = show_doc(html[..], U.w, U.h, scale, LAYER_UI, slot, drag, holes);
    place_at(LAYER_UI, 0.0, 0);
    // Pressed there, the bar moves the window; its controls are Goose's. No
    // window, no regions (a screenshot).
    tp_set_drag_regions(drag[..], holes[..]);
    return took;
}

// The boar on his rail, `t` seconds into a load, over the content's foot.
fn show_loader(F: UiFiles, U: Ui, t: f32, scale: f32) {
    // Without the load's phases yet, the rail fills toward its end and never
    // quite gets there.
    let p = 1.0 - exp(-t / 1.5);
    var html: u8[>..] = [];
    loader_html(F, U.w, p, t, html);
    var none = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var drag: f32[>..<] = [];
    var holes: f32[>..<] = [];
    show_doc(html[..], U.w, LOADER_H, scale, LAYER_LOADER, none, drag, holes);
    place_at(LAYER_LOADER, U.h - PANEL_H - LOADER_H, 2);
}

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame takes.
thread_fn wake_after(ms: i64, token: i32) {
    sleep_ms(ms);
    tp_wake(token);
}

fn usage() {
    write_stderr("usage: tusk [snapshot | --screenshot out.png [--at Y] [--size WxH] [--dev-tab NAME] [--bare] | --scroll-test | --idle-exit MS | --wake-test] [page.html ...]\n");
    exit(2);
}

fn main() {
    var mode = MODE_WINDOW;
    var shot: u8[>..] = [];
    var at: f32 = 0.0;
    var shot_w = WINDOW_W;
    var shot_h = WINDOW_H;
    var bare = false;
    var dev_tab = DEV_CONSOLE;
    var dev = true;                  // the dev panel shows
    var shot_only = false;           // an option only a screenshot takes was given
    var idle_exit_ms: i64 = -1;
    var paths: u8[>..] = [];         // the pages' paths, one after another
    var path_ends: i64[>..] = [];
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
            shot_only = true;
        } else if a == "--size" && valued {
            i += 1;
            let x = find(argv[i], "x");
            guard x > 0 else { usage(); return; }
            let w, wok = parse_int(argv[i][..x]);
            let h, hok = parse_int(argv[i][x + 1..]);
            guard wok && hok && w >= 100 && w <= 4000 && h >= 100 && h <= 4000 else { usage(); return; }
            shot_w = w;
            shot_h = h;
            shot_only = true;
        } else if a == "--dev-tab" && valued {
            i += 1;
            let names: const u8[:][5] = ["console", "network", "elements", "frames", "oil"];
            dev_tab = -1;
            for name, k in names { if argv[i] == name { dev_tab = k as i32; } }
            if argv[i] == "off" { dev_tab = DEV_CONSOLE; dev = false; }
            else { guard dev_tab >= 0 else { usage(); return; } }
            shot_only = true;
        } else if a == "--bare" {
            bare = true;
            shot_only = true;
        } else if a == "--idle-exit" && valued {
            i += 1;
            let n, ok = parse_int(argv[i]);
            guard ok && n >= 0 else { usage(); return; }
            idle_exit_ms = n;
        }
        else if a.len > 0 && a[0] != '-' && path_ends.len < MAX_TABS {
            full_path(a, paths);
            path_ends.push(paths.len);
        }
        else { usage(); return; }
        i += 1;
    }
    guard !shot_only || mode == MODE_SCREENSHOT else { usage(); return; }
    // The modes without a window show one page.
    guard (mode != MODE_SNAPSHOT && mode != MODE_SCREENSHOT) || path_ends.len <= 1 else { usage(); return; }
    if path_ends.len == 0 {
        full_path(str(resource_dir(), "../tests/pages/focaccia.html")[..], paths);
        path_ends.push(paths.len);
    }
    // The fonts Tusk brings (Barlow Condensed, JetBrains Mono), before any text is measured.
    tp_register_fonts(str(resource_dir(), "fonts")[..]);

    // A worker per page, at once: each loads while the window opens.
    var tabs: Tab[>..] = [];
    var names: i64[>..] = [];        // where each page's file name starts in `paths`
    var start: i64 = 0;
    for end, k in path_ends {
        var name = start;
        for j in start..end { if paths[j] == '/' { name = j + 1; } }
        names.push(name);
        tp_tab_open(k as i32);
        let info = FrameInfo { height: 0.0, background: 0xFFFFFFFF, nodes: 0, bytes: 0, parse: 0.0, style: 0.0,
                               measure: 0.0, layout: 0.0, scale: 1.0, read: 0.0 };
        let opened = clock_ns();
        let worker = thread_spawn_contained(tab_worker, k as i32, str(paths[start..end]));
        tabs.push(Tab { worker: worker, ready: false, failed: false, info: info, paint: 0.0, waiting: false, scroll: 0.0,
                        opened: opened, load_ms: 0.0, title_at: 0, title_len: 0, why_at: 0, why_len: 0, elems_at: 0,
                        elems_len: 0 });
        start = end;
    }

    if mode == MODE_SNAPSHOT {
        post(0, MSG_SNAPSHOT, SNAPSHOT_W, SNAPSHOT_H, 0.0);
        var head = ReplyHead { kind: 0, value: 0, len: 0 };
        var text: u8[>..<] = [];
        var done = false;
        while !done {
            guard tp_wait_tab(0, LOAD_WAIT_MS) == 2 else {
                write_stderr("tusk: the page didn't come\n");
                exit(1);
                return;
            }
            while take_reply(0, head, text) {
                guard head.kind != REPLY_FAILED else {
                    write_stderr(str("tusk: ", text, "\n"));
                    exit(1);
                    return;
                }
                if head.kind == REPLY_SNAPSHOT {
                    write_stdout(text);
                    done = true;
                }
            }
        }
        end_tabs(tabs);
        return;
    }

    // The interface's files, and the notes its tabs' titles and the rest are in.
    var css: u8[>..] = [];
    var sprite: u8[>..] = [];
    var rest: u8[>..] = [];
    var run: u8[>..] = [];
    let F = UiFiles { css: css, sprite: sprite, rest: rest, run: run };
    guard read_ui(F) else {
        write_stderr(str("tusk: the interface's files aren't in ", resource_dir(), "ui/\n"));
        exit(1);
        return;
    }
    var notes: u8[>..] = [];
    let T = UiText { paths: paths, path_ends: path_ends, names: names, notes: notes };
    // Its text is mostly what it was, each time it is laid out.
    tp_text_cache(SHAPE_CACHE);
    var U = Ui { w: WINDOW_W, h: WINDOW_H, lights: 0.0, cur: 0, dev: dev, dev_tab: dev_tab,
                 oil: tp_memory_footprint() / 1048576.0, cpu: 0.0, fps: 0, running: false };
    var slot = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };

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
        U.w = shot_w;
        U.h = shot_h;
        var first_ms: f32 = 0.0;
        if bare { slot = Rect { x: 0.0, y: 0.0, w: shot_w, h: shot_h }; }
        else { first_ms = show_ui(F, U, tabs, T, 0.0, scale, slot); }
        post(0, MSG_SIZE, slot.w, slot.h, scale);
        wait_for_frame(tabs, notes);
        let page_h = tabs[0].info.height;
        let y = clamp_scroll(at, page_h, slot.h);
        place_tab(0, true, y, slot);
        var bg = tabs[0].info.background;
        if !bare {
            U.oil = tp_memory_footprint() / 1048576.0;
            show_ui(F, U, tabs, T, first_ms, scale, slot);
            bg = STEEL;
        }
        let rc = tp_screenshot(shot, shot_w, shot_h, scale, bg);
        guard rc == 0 else {
            if rc == ERR_ARGUMENT {
                write_stderr("tusk: no screenshot: the file can't be written\n");
            } else {
                write_stderr(str("tusk: no screenshot: drawing it failed (error ", rc, ")\n"));
            }
            exit(1);
            return;
        }
        end_tabs(tabs);
        print("wrote ", shot, ": the window at 2x, scrolled to ", y, " of a page ", page_h, " points tall");
        return;
    }

    // The window opens at once, before any page is ready: its tabs come as
    // their workers finish.
    let title = "Tusk";
    // The window's bar is the interface's: the traffic lights go in it.
    guard tp_open(WINDOW_W, WINDOW_H, BAR_H, LIGHTS_X, title[0], title.len) == 0 else {
        write_stderr("tusk: could not open a window\n");
        exit(1);
        return;
    }
    U.lights = tp_lights_end() as f32;

    var worker: i64 = -1;
    if mode == MODE_WAKE_TEST { worker = thread_spawn_contained(wake_after, 300, 42); }

    var scale: f32 = 0.0;
    var woken = false;
    var pointer_x: f32 = -1.0;       // where the pointer is over the content, or -1 off it
    var pointer_y: f32 = -1.0;
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var ui_ms: f32 = 0.0;            // what laying the interface out took last
    var sized = Rect { x: 0.0, y: 0.0, w: -1.0, h: -1.0 };   // the slot the tabs were laid out for
    // The window's line: frames drawn for what changed on screen since it
    // was measured, when it was, and the CPU time then.
    var content_frames: i64 = 0;
    var tick_from = clock_ns();
    var cpu_from = tp_cpu_ns();
    var ticking = false;
    var settle = false;              // a frame has been drawn since the oil was last weighed
    var settle_at: i64 = 0;
    var quiet_from = clock_ns();     // the last event that wasn't a timer's
    var quit = false;
    while !quit {
        // Sleep until an event, or the first of the timers due: the window's
        // line while frames come, the boar's next step or start, the oil's
        // settling, the idle test's end.
        let now = clock_ns();
        var wait: i64 = -1;
        let t = tabs[U.cur];
        if !t.ready && !t.failed {
            let due = if U.running { STEP_MS } else { RUN_AFTER_MS - (ms(t.opened, now) as i64) };
            wait = max(due, 0);
        }
        if ticking { wait = soonest(wait, TICK_MS - (ms(tick_from, now) as i64)); }
        if settle { wait = soonest(wait, SETTLE_MS - (ms(settle_at, now) as i64)); }
        if idle_exit_ms >= 0 { wait = soonest(wait, idle_exit_ms - (ms(quiet_from, now) as i64)); }
        guard tp_next_event(wait, e) == 0 else {
            write_stderr("tusk: the window's events failed\n");
            exit(1);
            return;
        }
        // This event and every one already waiting, then at most one frame.
        let before = tabs[U.cur].scroll;
        let was = U.cur;
        var redo = false;            // the interface shows something else
        var arrived = false;         // the shown tab's display list
        var moved = false;
        var cursor: i32 = -1;
        if e.kind != EV_NONE {
            quiet_from = clock_ns();
            loop {
                if e.kind == EV_CLOSE { quit = true; }
                else if e.kind == EV_RESIZE {
                    U.w = e.w as f32;
                    U.h = e.h as f32;
                    scale = e.x as f32;
                    redo = true;
                } else if e.kind == EV_FRAME && e.code >= 0 && e.code < tabs.len {
                    // A hidden tab's display list waits in its mailbox, the
                    // latest replacing the one before, until the tab is shown:
                    // the main thread builds what it shows, and the GPU holds
                    // no more.
                    if e.code == U.cur {
                        let first = !tabs[e.code].ready;
                        if take_frame(tabs, e.code) {
                            arrived = true;
                            if first { redo = true; }
                        }
                    } else {
                        tabs[e.code].waiting = true;
                    }
                } else if e.kind == EV_REPLY && e.code >= 0 && e.code < tabs.len {
                    let k: i64 = e.code;
                    var shape: i32 = -1;
                    if read_replies(tabs, k, notes, head, text, shape) && k == U.cur { redo = true; }
                    if k == U.cur && shape >= 0 { cursor = shape; }
                    if k == U.cur { tp_set_title(title_of(tabs[k], T, k)); }
                } else if e.kind == EV_SCROLL {
                    pointer_x = e.w as f32;
                    pointer_y = e.h as f32;
                    // A wheel over the page scrolls it.
                    if in_slot(pointer_x, pointer_y, slot) {
                        let dy = e.y as f32;
                        tabs[U.cur].scroll -= if e.code == 1 { dy } else { dy * WHEEL_LINE };
                    }
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
                    let page = slot.h - 40.0;
                    if (mods & MOD_COMMAND) != 0 && (e.code == KEY_Q || e.code == KEY_W) { quit = true; }
                    else if (mods & MOD_COMMAND) != 0 && (mods & MOD_OPTION) != 0 && e.code == KEY_I {
                        // ⌘⌥I hides the dev panel, and the page takes its room; again, it shows.
                        U.dev = !U.dev;
                        redo = true;
                    }
                    else if (mods & MOD_COMMAND) != 0 {
                        for code, n in KEY_DIGITS { if e.code == code && n < tabs.len { U.cur = n; } }
                    }
                    else if e.code == KEY_SPACE { tabs[U.cur].scroll += if (mods & MOD_SHIFT) != 0 { -page } else { page }; }
                    else if e.code == KEY_PAGE_DOWN { tabs[U.cur].scroll += page; }
                    else if e.code == KEY_PAGE_UP { tabs[U.cur].scroll -= page; }
                    else if e.code == KEY_DOWN { tabs[U.cur].scroll += WHEEL_LINE; }
                    else if e.code == KEY_UP { tabs[U.cur].scroll -= WHEEL_LINE; }
                    else if e.code == KEY_HOME { tabs[U.cur].scroll = 0.0; }
                    else if e.code == KEY_END { tabs[U.cur].scroll = tabs[U.cur].info.height; }
                } else if e.kind == EV_WAKE {
                    print("woken by a worker, token ", e.code);
                    woken = true;
                    if mode == MODE_WAKE_TEST { quit = true; }
                }
                guard tp_next_event(0, e) == 0 && e.kind != EV_NONE else { break; }
            }
        } else if idle_exit_ms >= 0 && ms(quiet_from, clock_ns()) >= idle_exit_ms {
            break;
        }
        if quit { break; }
        let switched = U.cur != was;
        if switched {
            // Another tab: its waiting display list goes into its layer, the
            // one before hides, and the window takes its title.
            if tabs[was].ready { place_tab(was, false, tabs[was].scroll, slot); }
            if tabs[U.cur].waiting {
                tabs[U.cur].waiting = false;
                take_frame(tabs, U.cur);
            }
            tp_set_title(title_of(tabs[U.cur], T, U.cur));
            redo = true;
        }
        // The boar runs a load past RUN_AFTER_MS, and goes back to his bay when it ends.
        let shown = tabs[U.cur];
        let running = !shown.ready && !shown.failed && ms(shown.opened, clock_ns()) >= RUN_AFTER_MS;
        if running != U.running {
            U.running = running;
            redo = true;
            if !running { tp_drop_layer(LAYER_LOADER); }
        }
        // The window's line, measured every TICK_MS while frames come; once
        // they stop, it says so and the measuring stops.
        var drawn_line = false;
        if ticking && ms(tick_from, clock_ns()) >= TICK_MS {
            let now = clock_ns();
            let secs = ms(tick_from, now) / 1000.0;
            let cpu = tp_cpu_ns();
            let fps = round(content_frames / secs) as i32;
            let load = ((cpu - cpu_from) / 10000000.0 / secs) as f32;
            let oil = tp_memory_footprint() / 1048576.0;
            if fps != U.fps || abs(load - U.cpu) >= 0.1 || abs(oil - U.oil) >= 0.1 {
                U.fps = fps;
                U.cpu = load;
                U.oil = oil;
                redo = true;
                drawn_line = true;
            }
            ticking = fps > 0;
            tick_from = now;
            cpu_from = cpu;
            content_frames = 0;
        }
        // Drawing allocates memory the system only settles later: a while
        // after the last frame the oil is weighed again, once.
        if settle && ms(settle_at, clock_ns()) >= SETTLE_MS {
            settle = false;
            let oil = tp_memory_footprint() / 1048576.0;
            if abs(oil - U.oil) >= 0.1 {
                U.oil = oil;
                redo = true;
                drawn_line = true;
            }
        }
        if redo && U.w > 0.0 && scale > 0.0 {
            ui_ms = show_ui(F, U, tabs, T, ui_ms, scale, slot);
            // Every tab lays out again for a new slot at once, each on its own
            // core, so showing another is instant.
            if slot.w != sized.w || slot.h != sized.h {
                for t, k in tabs { post(k, MSG_SIZE, slot.w, slot.h, scale); }
                sized = slot;
            }
        }
        if U.running && scale > 0.0 { show_loader(F, U, ms(shown.opened, clock_ns()) as f32 / 1000.0, scale); }
        tabs[U.cur].scroll = clamp_scroll(tabs[U.cur].scroll, tabs[U.cur].info.height, slot.h);
        let scrolled = tabs[U.cur].scroll != before;
        // A frame only when what is on screen changed.
        if redo || arrived || scrolled || U.running {
            if tabs[U.cur].ready { place_tab(U.cur, true, tabs[U.cur].scroll, slot); }
            tp_render(STEEL);
            settle = true;
            settle_at = clock_ns();
            // The window line's own frames aren't what it counts.
            if !drawn_line || arrived || scrolled || switched {
                content_frames += 1;
                if !ticking {
                    ticking = true;
                    tick_from = clock_ns();
                    cpu_from = tp_cpu_ns();
                    content_frames = 1;
                }
            }
        }
        // Over a link the pointer is a hand, and elsewhere an arrow. What is
        // under it changes when it moves, and when the page moves under it:
        // the tab answers. Off the window (a scroll's momentum goes on after
        // it leaves) the cursor isn't ours.
        let inside = pointer_x >= 0.0 && pointer_x < U.w && pointer_y >= 0.0 && pointer_y < U.h;
        if cursor >= 0 && in_slot(pointer_x, pointer_y, slot) { tp_set_cursor(cursor); }
        if inside && (moved || arrived || switched || scrolled || redo) {
            if in_slot(pointer_x, pointer_y, slot) && tabs[U.cur].ready {
                post(U.cur, MSG_HIT, pointer_x - slot.x, pointer_y - slot.y + tabs[U.cur].scroll, 0.0);
            } else {
                tp_set_cursor(CURSOR_ARROW);
            }
        }
        if mode == MODE_SCROLL_TEST && tabs[U.cur].ready {
            scroll_test(tabs, U.cur, slot);
            quit = true;
        }
    }
    let worker_ok = worker < 0 || thread_wait(worker);
    var line: u8[>..] = [];
    weight(tabs[U.cur], T, U.cur, ui_ms, line);
    print(line);
    print("frames presented: ", tp_frames());
    tp_close();
    end_tabs(tabs);
    if mode == MODE_WAKE_TEST && !(woken && worker_ok) {
        write_stderr("tusk: the worker's wake never arrived\n");
        exit(1);
    }
}

// Path p onto `out`, from the root: one from where Tusk started goes under
// the shell's working directory ($PWD; left as it is without one), and its
// "." and ".." steps are taken.
fn full_path(p: const u8[:], out: u8[>..]&) {
    var whole: u8[>..] = [];
    if p.len > 0 && p[0] != '/' {
        var pwd: u8[>..] = [];
        if env("PWD", pwd) && pwd.len > 0 && pwd[0] == '/' {
            whole.append(pwd);
            whole.push('/');
        }
    }
    whole.append(p);
    guard whole[0] == '/' else { out.append(p); return; }
    let start = out.len;
    var i: i64 = 0;
    while i < whole.len {
        while i < whole.len && whole[i] == '/' { i += 1; }
        var j = i;
        while j < whole.len && whole[j] != '/' { j += 1; }
        let step = whole[i..j];
        if step == ".." {
            // Back to the slash before the last step.
            while out.len > start && out[out.len - 1] != '/' { out.resize(out.len - 1); }
            if out.len > start { out.resize(out.len - 1); }
        } else if step.len > 0 && step != "." {
            out.push('/');
            out.append(step);
        }
        i = j;
    }
    if out.len == start { out.push('/'); }
}

// The sooner of two waits in ms, -1 being none; never below 0.
fn soonest(a: i64, b: i64) -> i64 {
    let c = max(b, 0);
    return if a < 0 { c } else { min(a, c) };
}

fn in_slot(x: f32, y: f32, slot: Rect) -> bool {
    return x >= slot.x && x < slot.x + slot.w && y >= slot.y && y < slot.y + slot.h;
}

// What the page weighs and what each stage of showing it took, and the
// interface's last layout, for the console.
fn weight(t: Tab, T: UiText, k: i64, ui_ms: f32, line: u8[>..]&) {
    format(line, name_of(T, k), "  ");
    group(line, (t.info.bytes + 500) / 1000);
    line.append(" KB · ");
    group(line, t.info.nodes);
    line.append(" nodes · read ");
    format_flt(line, t.info.read, 1);
    line.append(" · parse ");
    format_flt(line, t.info.parse, 1);
    line.append(" · style ");
    format_flt(line, t.info.style, 1);
    line.append(" · text ");
    format_flt(line, t.info.measure, 1);
    line.append(" · layout ");
    format_flt(line, t.info.layout, 1);
    line.append(" · paint ");
    format_flt(line, t.paint, 1);
    line.append(" ms · interface ");
    format_flt(line, ui_ms, 1);
    line.append(" ms · ");
    format_flt(line, tp_memory_footprint() / 1048576.0, 1);
    line.append(" MB");
}

// Tells every tab to quit, waits for its worker and closes its mailbox. A
// worker that failed says why.
fn end_tabs(tabs: Tab[>..]&) {
    for t, k in tabs { post(k, MSG_QUIT, 0.0, 0.0, 0.0); }
    for t, k in tabs {
        var why: u8[>..] = [];
        if !thread_wait(t.worker, why) { write_stderr(str("tusk: tab ", k, " failed: ", why, "\n")); }
        tp_tab_drop(k as i32);
    }
}

// Scrolls down the page and back in its slot for 10 s at a brisk flick's
// speed, a frame per display refresh, the interface around it, and prints
// what the frames cost (docs/adr/0003).
fn scroll_test(tabs: Tab[>..]&, cur: i64, slot: Rect) {
    var stats = FrameStats { frames: 0, dropped: 0, refresh_hz: 0.0, max_interval_ms: 0.0, mean_interval_ms: 0.0,
                             max_cpu_ms: 0.0, max_gpu_ms: 0.0 };
    tp_frame_stats(stats, true);
    let travel = max(tabs[cur].info.height - slot.h, 1.0);
    let speed: f32 = 2000.0;       // points per second
    let start = clock_ns();
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    loop {
        // Keep AppKit's queue moving, as a real session would.
        while tp_next_event(0, e) == 0 && e.kind != EV_NONE {
            if e.kind == EV_CLOSE { return; }
            if e.kind == EV_KEY && ((e.x as i64) & MOD_COMMAND) != 0 && e.code == KEY_Q { return; }
            // A display list's wake comes once: taking it lets the next one wake.
            if e.kind == EV_FRAME && e.code == cur { take_frame(tabs, cur); }
            if e.kind == EV_FRAME && e.code != cur && e.code >= 0 && e.code < tabs.len { tabs[e.code].waiting = true; }
        }
        let s = ms(start, clock_ns()) / 1000.0;
        if s >= 10.0 { break; }
        let d = speed * s;
        let laps = floor(d / (2.0 * travel));
        let p = d - laps * 2.0 * travel;
        place_tab(cur, true, (if p < travel { p } else { 2.0 * travel - p }) as f32, slot);
        tp_render(STEEL);
    }
    tp_frame_stats(stats, false);
    print("scroll test: ", stats.frames, " frames in 10 s at ", stats.refresh_hz, " Hz; dropped ", stats.dropped,
          "; frame interval mean ", stats.mean_interval_ms, " ms, max ", stats.max_interval_ms,
          " ms; per frame CPU max ", stats.max_cpu_ms, " ms, GPU max ", stats.max_gpu_ms, " ms; memory ",
          tp_memory_footprint() / 1048576, " MB");
}
