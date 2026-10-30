// Tusk's app (docs/adr/0005, 0010): opens saved pages, each in a tab whose
// worker loads and lays it out (tab.goose), and shows one at a time on the
// compositor (docs/adr/0003). The main thread owns the window and the
// compositor and lays no page out. It sleeps until something happens; a
// scroll moves what is already on the GPU and nothing else, and an idle window
// draws nothing. The bar at the bottom shows the page's weight.
//
//   tusk [page.html ...]                 open pages, one tab each (the Focaccia article by default);
//                                        ⌘1 to ⌘9 show a tab
//   tusk snapshot [page.html]            print the page as a tree for agents (docs/adr/0007)
//   tusk --screenshot out.png [--at Y] [--size WxH] [page.html]
//                                        draw the window offscreen into a PNG; no window opens;
//                                        --size makes its page W × H points, the bar below
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

struct Event { kind: i32, code: i32, x: f64, y: f64, w: f64, h: f64 }

// Where a layer goes (platform/src/compositor.rs, Place), in points: its
// content's point (scroll_x, scroll_y) lands on the window's (x, y), and a, b,
// c, d turn and scale it about there (all 0: none). With clip_w above 0 it
// shows only inside its clip, measured from where it lands, its corners
// rounded by radius; it is faded by opacity and drawn over the layers of a
// lower z, and only when shown isn't 0. Placing a layer rebuilds nothing.
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
    fn tp_set_title(title: const u8[:]) -> i32;
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
let KEY_SPACE: i32 = 49;
let KEY_HOME: i32 = 115;
let KEY_PAGE_UP: i32 = 116;
let KEY_END: i32 = 119;
let KEY_PAGE_DOWN: i32 = 121;
let KEY_DOWN: i32 = 125;
let KEY_UP: i32 = 126;
let KEY_DIGITS: i32[9] = [18, 19, 20, 21, 23, 22, 26, 28, 25];   // 1 to 9
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
let MAX_TABS: i64 = 60;          // tab k draws in layer k
let LAYER_BAR: i32 = 63;         // the last layer, over every tab
let LOAD_WAIT_MS: i64 = 60000;   // how long the modes without a window wait for a page
let ERR_ARGUMENT: i32 = -4;      // platform/src/lib.rs
let ERR_NO_DEVICE: i32 = -5;     // platform/src/lib.rs

// What the main thread knows of a tab: its worker, what came with its last
// display list (`ready` once one has) and what building it cost here, how
// far it is scrolled, and its title, a span of the titles' bytes.
struct Tab { worker: i64, ready: bool, info: FrameInfo, paint: f32, scroll: f32, title_at: i64, title_len: i64 }

fn ms(from: i64, to: i64) -> f64 { return (to - from) / 1000000.0; }

// Hands a layer to the compositor. One it refuses would leave the window or
// the screenshot without it, so Tusk stops and says why.
fn set_layer(layer: i32, items: const DItem[:], text: const u8[:], paths: const f32[:], scale: f32) {
    let rc = tp_set_layer(layer, items, text, paths, scale);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused layer ", layer, " (error ", rc, ")\n"));
    exit(1);
}

// Tab k's layer: scrolled by `scroll`, shown (or not) only in its view,
// `width` × `view_h` at the window's corner, which spares the GPU the rest. A
// window shorter than the bar leaves the view no room.
fn place_tab(k: i64, shown: bool, scroll: f32, width: f32, view_h: f32) {
    let p = Place { x: 0.0, y: 0.0, scroll_x: 0.0, scroll_y: scroll, a: 0.0, b: 0.0, c: 0.0, d: 0.0,
                    clip_x: 0.0, clip_y: 0.0, clip_w: max(width, 0.0), clip_h: max(view_h, 0.0), radius: 0.0,
                    opacity: 1.0, z: 0, shown: if shown { 1 } else { 0 } };
    let rc = tp_place_layer(k as i32, p);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused a tab's place (error ", rc, ")\n"));
    exit(1);
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
    tabs[k].ready = true;
    return true;
}

// What the page weighs and what each stage of showing it took.
fn weight(t: Tab, name: const u8[:], line: u8[>..]&) {
    format(line, name, "  ");
    group(line, (t.info.bytes + 500) / 1000);
    line.append(" KB · ");
    group(line, t.info.nodes);
    line.append(" nodes · parse ");
    format_flt(line, t.info.parse, 1);
    line.append(" · style ");
    format_flt(line, t.info.style, 1);
    line.append(" · text ");
    format_flt(line, t.info.measure, 1);
    line.append(" · layout ");
    format_flt(line, t.info.layout, 1);
    line.append(" · paint ");
    format_flt(line, t.paint, 1);
    line.append(" ms · ");
    format_flt(line, tp_memory_footprint() / 1048576.0, 1);
    line.append(" MB");
}

// The bar along the bottom of the window, with the page's weight.
fn show_bar(t: Tab, name: const u8[:], width: f32, height: f32, scale: f32) {
    var line: u8[>..] = [];
    weight(t, name, line);
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
    tp_take_reply(k as i32, text[..]);
    return true;
}

// Waits, without a window, for tab 0's display list, reading its replies
// meanwhile; stops Tusk if the page fails or never comes.
fn wait_for_frame(tabs: Tab[>..]&) {
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
    loop {
        let got = tp_wait_tab(0, LOAD_WAIT_MS);
        guard got == 1 || got == 2 else {
            write_stderr("tusk: the page didn't come\n");
            exit(1);
            return;
        }
        if got == 1 && take_frame(tabs, 0) { return; }
        while take_reply(0, head, text) {
            guard head.kind != REPLY_FAILED else {
                write_stderr(str("tusk: ", text, "\n"));
                exit(1);
                return;
            }
        }
    }
}

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame takes.
thread_fn wake_after(ms: i64, token: i32) {
    sleep_ms(ms);
    tp_wake(token);
}

fn usage() {
    write_stderr("usage: tusk [snapshot | --screenshot out.png [--at Y] [--size WxH] | --scroll-test | --idle-exit MS | --wake-test] [page.html ...]\n");
    exit(2);
}

fn main() {
    var mode = MODE_WINDOW;
    var shot: u8[>..] = [];
    var at: f32 = 0.0;
    var has_at = false;
    var shot_w = WINDOW_W;           // --size: the page's view in a screenshot, the bar below it
    var shot_h = WINDOW_H - BAR_H;
    var has_size = false;
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
        else if a.len > 0 && a[0] != '-' && path_ends.len < MAX_TABS {
            paths.append(a);
            path_ends.push(paths.len);
        }
        else { usage(); return; }
        i += 1;
    }
    guard (!has_at && !has_size) || mode == MODE_SCREENSHOT else { usage(); return; }
    // The modes without a window show one page.
    guard (mode != MODE_SNAPSHOT && mode != MODE_SCREENSHOT) || path_ends.len <= 1 else { usage(); return; }
    if path_ends.len == 0 {
        paths.append(str(resource_dir(), "../tests/pages/focaccia.html"));
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
                               measure: 0.0, layout: 0.0, scale: 1.0 };
        let worker = thread_spawn_contained(tab_worker, k as i32, str(paths[start..end]));
        tabs.push(Tab { worker: worker, ready: false, info: info, paint: 0.0, scroll: 0.0, title_at: 0, title_len: 0 });
        start = end;
    }

    if mode == MODE_SNAPSHOT {
        post(0, MSG_SNAPSHOT, WINDOW_W, WINDOW_H - BAR_H, 0.0);
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
        post(0, MSG_SIZE, shot_w, shot_h, scale);
        wait_for_frame(tabs);
        let page_h = tabs[0].info.height;
        let y = clamp_scroll(at, page_h, shot_h);
        place_tab(0, true, y, shot_w, shot_h);
        show_bar(tabs[0], paths[names[0]..path_ends[0]], shot_w, shot_h + BAR_H, scale);
        let rc = tp_screenshot(shot, shot_w, shot_h + BAR_H, scale, tabs[0].info.background);
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
    var cur: i64 = 0;                // the tab shown
    var settle = false;              // a frame has been drawn since the bar last weighed the page
    var woken = false;
    var titles: u8[>..] = [];        // every tab's title, one after another
    var pointer_x: f32 = -1.0;       // where the pointer is over the content, or -1 off it
    var pointer_y: f32 = -1.0;
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
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
            if tabs[cur].ready {
                show_bar(tabs[cur], paths[names[cur]..path_ends[cur]], width, height, scale);
                tp_render(tabs[cur].info.background);
            }
            continue;
        }
        // This event and every one already waiting, then at most one frame.
        let before = tabs[cur].scroll;
        let was = cur;
        var resized = false;
        var arrived = false;         // the shown tab's display list
        var moved = false;
        loop {
            if e.kind == EV_CLOSE { quit = true; }
            else if e.kind == EV_RESIZE {
                let w = e.w as f32;
                let s = e.x as f32;
                // Every tab lays out again at once, each on its own core, so
                // showing another is instant.
                if w != width || s != scale || e.h as f32 != height {
                    for t, k in tabs { post(k, MSG_SIZE, w, max(e.h as f32 - BAR_H, 0.0), s); }
                }
                width = w;
                height = e.h as f32;
                scale = s;
                resized = true;
            } else if e.kind == EV_FRAME && e.code >= 0 && e.code < tabs.len {
                if take_frame(tabs, e.code) && e.code == cur { arrived = true; }
            } else if e.kind == EV_REPLY && e.code >= 0 && e.code < tabs.len {
                let k: i64 = e.code;
                while take_reply(k, head, text) {
                    // A tab's answer counts while the pointer is still over its page.
                    let over = pointer_x >= 0.0 && pointer_x < width && pointer_y >= 0.0 && pointer_y < height - BAR_H;
                    if head.kind == REPLY_HIT && k == cur && over { tp_set_cursor(head.value); }
                    else if head.kind == REPLY_TITLE {
                        tabs[k].title_at = titles.len;
                        titles.append(text);
                        tabs[k].title_len = text.len;
                        if k == cur && text.len > 0 { tp_set_title(text); }
                    }
                    else if head.kind == REPLY_FAILED { write_stderr(str("tusk: ", text, "\n")); }
                }
            } else if e.kind == EV_SCROLL {
                let dy = e.y as f32;
                tabs[cur].scroll -= if e.code == 1 { dy } else { dy * WHEEL_LINE };
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
                else if (mods & MOD_COMMAND) != 0 {
                    for code, n in KEY_DIGITS { if e.code == code && n < tabs.len { cur = n; } }
                }
                else if e.code == KEY_SPACE { tabs[cur].scroll += if (mods & MOD_SHIFT) != 0 { -page } else { page }; }
                else if e.code == KEY_PAGE_DOWN { tabs[cur].scroll += page; }
                else if e.code == KEY_PAGE_UP { tabs[cur].scroll -= page; }
                else if e.code == KEY_DOWN { tabs[cur].scroll += WHEEL_LINE; }
                else if e.code == KEY_UP { tabs[cur].scroll -= WHEEL_LINE; }
                else if e.code == KEY_HOME { tabs[cur].scroll = 0.0; }
                else if e.code == KEY_END { tabs[cur].scroll = tabs[cur].info.height; }
            } else if e.kind == EV_WAKE {
                print("woken by a worker, token ", e.code);
                woken = true;
                if mode == MODE_WAKE_TEST { quit = true; }
            }
            guard tp_next_event(0, e) == 0 && e.kind != EV_NONE else { break; }
        }
        if quit { break; }
        let view_h = height - BAR_H;
        let switched = cur != was;
        if switched {
            // Another tab: its layer shows, the one before hides, and the
            // window takes its title.
            place_tab(was, false, tabs[was].scroll, width, view_h);
            if tabs[cur].title_len > 0 { tp_set_title(titles[tabs[cur].title_at..tabs[cur].title_at + tabs[cur].title_len]); }
        }
        tabs[cur].scroll = clamp_scroll(tabs[cur].scroll, tabs[cur].info.height, view_h);
        // The bar sits at the window's bottom edge: it moves with any resize.
        if tabs[cur].ready && (resized || arrived || switched) {
            show_bar(tabs[cur], paths[names[cur]..path_ends[cur]], width, height, scale);
        }
        // A frame only when what is on screen changed.
        if tabs[cur].ready && (resized || arrived || switched || tabs[cur].scroll != before) {
            place_tab(cur, true, tabs[cur].scroll, width, view_h);
            tp_render(tabs[cur].info.background);
            settle = true;
        }
        // Over a link the pointer is a hand, and over the bar an arrow. What is
        // under it changes when it moves, and when the page moves under it:
        // the tab answers. Off the window (a scroll's momentum goes on after
        // it leaves) the cursor isn't ours.
        let inside = pointer_x >= 0.0 && pointer_x < width && pointer_y >= 0.0 && pointer_y < height;
        if inside && (moved || arrived || switched || tabs[cur].scroll != before) {
            if pointer_y < view_h { post(cur, MSG_HIT, pointer_x, pointer_y + tabs[cur].scroll, 0.0); }
            else { tp_set_cursor(CURSOR_ARROW); }
        }
        if mode == MODE_SCROLL_TEST && tabs[cur].ready {
            scroll_test(tabs[cur], width, height);
            quit = true;
        }
    }
    let worker_ok = worker < 0 || thread_wait(worker);
    var line: u8[>..] = [];
    weight(tabs[cur], paths[names[cur]..path_ends[cur]], line);
    print(line);
    print("frames presented: ", tp_frames());
    tp_close();
    end_tabs(tabs);
    if mode == MODE_WAKE_TEST && !(woken && worker_ok) {
        write_stderr("tusk: the worker's wake never arrived\n");
        exit(1);
    }
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

// Scrolls down the page and back for 10 s at a brisk flick's speed, a frame
// per display refresh, and prints what the frames cost (docs/adr/0003).
fn scroll_test(t: Tab, width: f32, height: f32) {
    var stats = FrameStats { frames: 0, dropped: 0, refresh_hz: 0.0, max_interval_ms: 0.0, mean_interval_ms: 0.0,
                             max_cpu_ms: 0.0, max_gpu_ms: 0.0 };
    tp_frame_stats(stats, true);
    let travel = max(t.info.height - (height - BAR_H), 1.0);
    let speed: f32 = 2000.0;       // points per second
    let start = clock_ns();
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    loop {
        // Keep AppKit's queue moving, as a real session would.
        while tp_next_event(0, e) == 0 && e.kind != EV_NONE {
            if e.kind == EV_CLOSE { return; }
            if e.kind == EV_KEY && ((e.x as i64) & MOD_COMMAND) != 0 && e.code == KEY_Q { return; }
        }
        let s = ms(start, clock_ns()) / 1000.0;
        if s >= 10.0 { break; }
        let d = speed * s;
        let laps = floor(d / (2.0 * travel));
        let p = d - laps * 2.0 * travel;
        place_tab(0, true, (if p < travel { p } else { 2.0 * travel - p }) as f32, width, height - BAR_H);
        tp_render(t.info.background);
    }
    tp_frame_stats(stats, false);
    print("scroll test: ", stats.frames, " frames in 10 s at ", stats.refresh_hz, " Hz; dropped ", stats.dropped,
          "; frame interval mean ", stats.mean_interval_ms, " ms, max ", stats.max_interval_ms,
          " ms; per frame CPU max ", stats.max_cpu_ms, " ms, GPU max ", stats.max_gpu_ms, " ms; memory ",
          tp_memory_footprint() / 1048576, " MB");
}
