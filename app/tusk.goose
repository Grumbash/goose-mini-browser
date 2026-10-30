// Tusk's app (docs/adr/0005, 0010, 0011): opens pages, saved or on the web,
// each in a tab whose worker loads and lays it out (tab.goose), and shows them
// in its interface
// (ui.goose): a document laid out here, on the main thread, when what it shows
// changes, with the page in focus drawn where it marks its slot (docs/adr/0003).
// The main thread owns the window and the compositor and lays no page out. It
// sleeps until something happens; a scroll moves what is already on the GPU
// and nothing else, and an idle window draws nothing.
//
//   tusk [page ...]                      open pages, one tab each: files, or http and https URLs
//                                        (the Focaccia article by default); a click on a link
//                                        follows it (⌘-click: in a new tab); ⌘[ and ⌘] go back
//                                        and forward, ⌘R reloads (⌘⇧R past the cache), Esc stops
//                                        a load; ⌘L types where to go (Return opens it, ⌘Return in
//                                        a new tab: a URL, a path, a host or a search), ⌘1 to ⌘9
//                                        show a tab, ⌘⌥I hides the dev panel, ⌘⇧S opens the page
//                                        in Safari
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
import .net;
import .sheets;
import .history;
import .address;

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

// The pages' workers: the next mailbox to give one, the profile and dark
// mode they load with, and those told to quit that haven't said they've
// gone, with their mailboxes.
struct Pages { next: i32, profile: i32, dark: bool, workers: i64[>..]&, ids: i32[>..]& }

// Where a page's link leads, from its replies: nowhere, another page, another
// page in a new tab, or a place on the page (`y`; -1: none), its URL a span
// of the notes.
struct Follow { kind: i32, y: i32, at: i64, len: i64 }
let FOLLOW_NONE: i32 = 0;
let FOLLOW_LINK: i32 = 1;
let FOLLOW_NEW_TAB: i32 = 2;
let FOLLOW_JUMP: i32 = 3;

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
    fn tp_mac_memory(total: i64&, used: i64&) -> i32;
    fn tp_mac_cpu(busy: i64&, total: i64&) -> i32;
    fn tp_cpu_ns() -> i64;
    fn tp_cores() -> i64;
    fn tp_frames() -> i64;
    fn tp_close() -> i32;
    fn tp_wake(token: i32) -> i32;
    fn tp_set_cursor(kind: i32) -> i32;
    fn tp_set_title(title: const u8[:]) -> i32;
    fn tp_text_cache(limit_bytes: i64) -> i32;
    fn tp_dark_mode() -> i32;
    fn tp_key_text(out: u8[:]) -> i32;
    fn tp_paste(out: u8[:]) -> i32;
    fn tp_copy(text: const u8[:]) -> i32;
}

// Event kinds, as numbered in platform/src/lib.rs.
let EV_NONE: i32 = 0;
let EV_CLOSE: i32 = 1;
let EV_RESIZE: i32 = 2;
let EV_KEY: i32 = 3;
let EV_MOUSE: i32 = 4;
let EV_SCROLL: i32 = 5;
let EV_WAKE: i32 = 6;
let EV_MOUSE_UP: i32 = 7;
let EV_MOUSE_MOVE: i32 = 8;
let EV_MOUSE_LEAVE: i32 = 9;
let EV_FRAME: i32 = 10;          // code: a tab whose display list waits
let EV_REPLY: i32 = 11;          // code: a tab whose reply waits

// macOS virtual key codes and modifier flags.
let KEY_Q: i32 = 12;
let KEY_W: i32 = 13;
let KEY_S: i32 = 1;
let KEY_A: i32 = 0;
let KEY_C: i32 = 8;
let KEY_V: i32 = 9;
let KEY_X: i32 = 7;
let KEY_L: i32 = 37;
let KEY_RETURN: i32 = 36;
let KEY_ENTER: i32 = 76;           // the keypad's
let KEY_DELETE: i32 = 51;          // ⌫
let KEY_FORWARD_DELETE: i32 = 117; // ⌦
let KEY_R: i32 = 15;
let KEY_LEFT_BRACKET: i32 = 33;
let KEY_RIGHT_BRACKET: i32 = 30;
let KEY_ESCAPE: i32 = 53;
let KEY_LEFT: i32 = 123;
let KEY_RIGHT: i32 = 124;
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
let MAX_PAGE: f32 = 8000000.0;   // how far down a page scrolls (whole points in an f32: 2^23)
let SHAPE_CACHE: i64 = 4 << 20;  // the interface's shaped text kept, in bytes
let CLICK_SLOP: f32 = 4.0;       // points a press may move and still be a click
let ERR_ARGUMENT: i32 = -4;      // platform/src/lib.rs
let ERR_NO_DEVICE: i32 = -5;     // platform/src/lib.rs

fn ms(from: i64, to: i64) -> f64 { return (to - from) / 1000000.0; }

// A layer's place. One the compositor refuses (past its range) leaves the
// layer where it was, and Tusk says so and goes on.
fn place(layer: i32, p: Place) {
    let rc = tp_place_layer(layer, p);
    guard rc != 0 else { return; }
    write_stderr(str("tusk: the compositor refused layer ", layer, "'s place (error ", rc, ")\n"));
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

// Takes tab k's waiting display list into its layer; true if one waited. A
// page's first scrolls to where the tab is to go back to.
fn take_frame(tabs: Tab[>..]&, k: i64) -> bool {
    let t0 = clock_ns();
    let got = tp_take_frame(tabs[k].page, k as i32, tabs[k].info);
    guard got >= 0 else {
        write_stderr(str("tusk: the compositor refused tab ", k, "'s page (error ", got, ")\n"));
        exit(1);
        return false;
    }
    guard got == 1 else { return false; }
    tabs[k].paint = ms(t0, clock_ns()) as f32;
    // What loading the page took its worker; the wait to be shown isn't.
    let i = tabs[k].info;
    if !tabs[k].ready {
        tabs[k].load_ms = i.read + i.parse + i.style + i.measure + i.layout;
        if tabs[k].restore >= 0.0 { tabs[k].scroll = tabs[k].restore; }
        tabs[k].restore = -1.0;
    }
    tabs[k].ready = true;
    return true;
}

// Reads tab k's waiting replies into its state; true if one changes what the
// interface shows. A hit's pointer shape goes to `cursor` (-1: none came),
// `titled` says whether its title came, or why it failed, and where a
// clicked link leads goes to `follow`.
fn read_replies(tabs: Tab[>..]&, k: i64, notes: u8[>..]&, head: ReplyHead&, text: u8[>..<]&, cursor: i32&,
                titled: bool&, follow: Follow&) -> bool {
    var changed = false;
    while take_reply(tabs[k].page, head, text) {
        if head.kind == REPLY_HIT { cursor = head.value; continue; }
        if head.kind == REPLY_GONE { continue; }
        if head.kind == REPLY_LINK || head.kind == REPLY_JUMP {
            follow = Follow { kind: if head.kind == REPLY_JUMP { FOLLOW_JUMP } else if head.value == 1 { FOLLOW_NEW_TAB }
                                    else { FOLLOW_LINK },
                              y: head.value, at: notes.len, len: text.len };
            notes.append(text);
            continue;
        }
        changed = true;
        if head.kind == REPLY_READ {
            // Known before its display list is: a hidden tab's weighs this too.
            if !tabs[k].ready { tabs[k].info.bytes = head.value; }
            continue;
        }
        if head.kind == REPLY_TITLE || head.kind == REPLY_FAILED { titled = true; }
        if head.kind == REPLY_TITLE {
            tabs[k].title_at = notes.len;
            tabs[k].title_len = text.len;
        } else if head.kind == REPLY_ELEMENTS {
            tabs[k].elems_at = notes.len;
            tabs[k].elems_len = text.len;
        } else if head.kind == REPLY_LOG {
            tabs[k].log_at = notes.len;
            tabs[k].log_len = text.len;
        } else if head.kind == REPLY_URL {
            // Where the page ended up, after its redirects.
            tabs[k].status = head.value;
            tabs[k].loc_at = notes.len;
            tabs[k].loc_len = text.len;
        } else if head.kind == REPLY_FAILED {
            write_stderr(str("tusk: ", text, "\n"));
            tabs[k].failed = true;
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

// A scroll kept within the page; and within MAX_PAGE, where a point's place
// still holds in an f32, which the compositor's range takes in too.
fn clamp_scroll(y: f32, page_h: f32, view_h: f32) -> f32 {
    return max(min(y, min(page_h, MAX_PAGE) - view_h), 0.0);
}

// Posts a message to page `page`'s worker; none goes to no page (-1).
fn post(page: i32, kind: i32, a: f32, b: f32, c: f32) {
    guard page >= 0 else { return; }
    let m = TabMsg { kind: kind, a: a, b: b, c: c };
    tp_tab_post(page, m);
}

// Takes page `page`'s next waiting reply: its head into `head` and its text
// into `text`. False when none waits.
fn take_reply(page: i32, head: ReplyHead&, text: u8[>..<]&) -> bool {
    guard page >= 0 && tp_reply_head(page, head) == 1 else { return false; }
    text.resize(0);
    for i in head.len { text.push(0); }
    return tp_take_reply(page, head, text[..]) == 0;
}

// The tab whose page is `page`, or -1: a page that has been left.
fn tab_of(tabs: const Tab[:], page: i32) -> i64 {
    for t, k in tabs { if t.page == page && page >= 0 { return k; } }
    return -1;
}

// Tells tab k's page to quit and lets it go: its worker is reaped when it
// says it has gone (reap), so the window never waits for it.
fn retire(tabs: Tab[>..]&, k: i64, pages: Pages&) {
    guard tabs[k].page >= 0 else { return; }
    post(tabs[k].page, MSG_QUIT, 0.0, 0.0, 0.0);
    pages.workers.push(tabs[k].worker);
    pages.ids.push(tabs[k].page);
    tabs[k].worker = -1;
    tabs[k].page = -1;
}

// Reads what a page that has been left still says; once it says it has gone,
// waits for its worker, which has returned, and closes its mailbox.
fn reap(pages: Pages&, page: i32, head: ReplyHead&, text: u8[>..<]&) {
    var gone = false;
    while take_reply(page, head, text) { if head.kind == REPLY_GONE { gone = true; } }
    guard gone else { return; }
    for id, j in pages.ids {
        guard id == page else { continue; }
        var why: u8[>..] = [];
        if !thread_wait(pages.workers[j], why) { write_stderr(str("tusk: a page left behind failed: ", why, "\n")); }
        tp_tab_drop(page);
        pages.ids[j] = -1;
        return;
    }
}

// Loads where tab k is to be (the span of the notes `at`, `len`) in a new
// page: the one it showed is let go, but stays on screen until the new one
// draws. Scrolls to `restore` once it comes (-1: the top), past the cache
// when `reload` says so, and lays it out for `slot` at `scale` (0: not yet
// known).
fn load(tabs: Tab[>..]&, k: i64, notes: const u8[:], at: i64, len: i64, restore: f32, reload: bool, pages: Pages&,
        slot: Rect, scale: f32) {
    retire(tabs, k, pages);
    let page = pages.next;
    pages.next += 1;
    tp_tab_open(page);
    let worker = thread_spawn_contained(tab_worker, page, str(notes[at..at + len]), pages.profile, pages.dark, reload);
    let info = FrameInfo { height: 0.0, background: 0xFFFFFFFF, nodes: 0, bytes: 0, parse: 0.0, style: 0.0,
                           measure: 0.0, layout: 0.0, scale: 1.0, read: 0.0 };
    tabs[k].worker = worker;
    tabs[k].page = page;
    tabs[k].ready = false;
    tabs[k].failed = false;
    tabs[k].info = info;
    tabs[k].waiting = false;
    tabs[k].scroll = 0.0;
    tabs[k].restore = restore;
    tabs[k].opened = clock_ns();
    tabs[k].load_ms = 0.0;
    tabs[k].status = 0;
    tabs[k].loc_at = at;
    tabs[k].loc_len = len;
    tabs[k].title_len = 0;
    tabs[k].why_len = 0;
    tabs[k].log_len = 0;
    tabs[k].elems_len = 0;
    if scale > 0.0 && slot.w > 0.0 { post(page, MSG_SIZE, slot.w, slot.h, scale); }
}

// Tab k goes back or forward to place j of its history: on the page it shows
// (another place on it), it scrolls there; else it loads the page and
// scrolls once it comes.
fn go(tabs: Tab[>..]&, k: i64, entries: Entry[>..]&, j: i64, notes: const u8[:], pages: Pages&, slot: Rect,
      scale: f32) {
    guard j >= 0 else { return; }
    let cur = tabs[k].entry;
    if cur >= 0 { entries[cur].scroll = tabs[k].scroll; }
    let e = entries[j];
    tabs[k].entry = j;
    let here = notes[tabs[k].loc_at..tabs[k].loc_at + tabs[k].loc_len];
    let there = notes[e.loc_at..e.loc_at + e.loc_len];
    if tabs[k].ready && doc_part(here) == doc_part(there) {
        tabs[k].loc_at = e.loc_at;
        tabs[k].loc_len = e.loc_len;
        tabs[k].scroll = e.scroll;
        return;
    }
    load(tabs, k, notes, e.loc_at, e.loc_len, e.scroll, false, pages, slot, scale);
}

// Waits, without a window, for tab 0's display list, reading its replies
// meanwhile; stops Tusk if the page fails or never comes.
fn wait_for_frame(tabs: Tab[>..]&, notes: u8[>..]&) {
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
    var cursor: i32 = -1;
    var titled = false;
    var follow = Follow { kind: FOLLOW_NONE, y: 0, at: 0, len: 0 };
    loop {
        let got = tp_wait_tab(tabs[0].page, LOAD_WAIT_MS);
        guard got == 1 || got == 2 else {
            write_stderr("tusk: the page didn't come\n");
            exit(1);
            return;
        }
        if got == 1 && take_frame(tabs, 0) {
            // Its title and elements came before it.
            read_replies(tabs, 0, notes, head, text, cursor, titled, follow);
            return;
        }
        read_replies(tabs, 0, notes, head, text, cursor, titled, follow);
        guard !tabs[0].failed else { exit(1); return; }
    }
}

// The interface for what Tusk shows now, into its layer; its slot into
// `slot`. Returns what laying it out took, in ms.
fn show_ui(F: UiFiles, U: Ui, tabs: const Tab[:], T: UiText, last_ms: f32, scale: f32, slot: Rect&,
           actions: f32[>..<]&) -> f32 {
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
    actions.resize(0);
    let took = show_doc(html[..], U.w, U.h, scale, LAYER_UI, slot, drag, holes, actions);
    place_at(LAYER_UI, 0.0, 0);
    // Pressed there, the bar moves the window; its controls are Goose's. No
    // window, no regions (a screenshot).
    tp_set_drag_regions(drag[..], holes[..]);
    return took;
}

// The boar on his rail, `t` seconds into tab k's load, over the content's foot.
fn show_loader(F: UiFiles, U: Ui, k: i64, t: f32, scale: f32) {
    // The rail fills with the document's bytes as they come, when the server
    // said how many; else, and for a file, toward its end, never quite there.
    var got: i64 = 0;
    var of: i64 = -1;
    var p = 1.0 - exp(-t / 1.5);
    if tp_net_progress(k as i32, got, of) == 1 && of > 0 { p = min((got / of) as f32, 1.0); }
    var html: u8[>..] = [];
    loader_html(F, U.w, p, t, html);
    var none = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var drag: f32[>..<] = [];
    var holes: f32[>..<] = [];
    var actions: f32[>..<] = [];
    show_doc(html[..], U.w, LOADER_H, scale, LAYER_LOADER, none, drag, holes, actions);
    place_at(LAYER_LOADER, U.h - PANEL_H - LOADER_H, 2);
}

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame takes.
thread_fn wake_after(ms: i64, token: i32) {
    sleep_ms(ms);
    tp_wake(token);
}

fn usage() {
    write_stderr("usage: tusk [snapshot | --screenshot out.png [--at Y] [--size WxH] [--dev-tab NAME] [--bare] | --scroll-test | --idle-exit MS | --wake-test] [page.html | URL ...]\n");
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
    var paths: u8[>..] = [];         // where the pages are, paths and URLs, one after another
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
            if is_web(a) {
                guard resolve_url(a, a, paths) else { usage(); return; }
            } else {
                full_path(a, paths);
            }
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
    // The window's pages are ours; what a test or a picture loads keeps nothing.
    let profile = if mode == MODE_WINDOW { PROFILE_DEFAULT } else { PROFILE_SANDBOX };
    // Pages see the system's dark mode in the window; a picture or a test, light.
    let dark = mode == MODE_WINDOW && tp_dark_mode() == 1;

    // A worker per page, at once: each loads while the window opens. Where
    // each page is, and later its title and the rest, are notes the tabs
    // point into.
    var notes: u8[>..] = [];
    notes.append(paths);
    var tabs: Tab[>..] = [];
    var entries: Entry[>..] = [];    // the tabs' histories
    var leaving: i64[>..] = [];      // workers of pages left, until they've gone
    var leaving_ids: i32[>..] = [];
    var pages = Pages { next: 0, profile: profile, dark: dark, workers: leaving, ids: leaving_ids };
    let none = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var start: i64 = 0;
    for end, k in path_ends {
        open_tab(tabs, entries, notes, start, end - start, pages, none, 0.0);
        start = end;
    }

    if mode == MODE_SNAPSHOT {
        post(tabs[0].page, MSG_SNAPSHOT, SNAPSHOT_W, SNAPSHOT_H, 0.0);
        var head = ReplyHead { kind: 0, value: 0, len: 0 };
        var text: u8[>..<] = [];
        var done = false;
        while !done {
            guard tp_wait_tab(tabs[0].page, LOAD_WAIT_MS) == 2 else {
                write_stderr("tusk: the page didn't come\n");
                exit(1);
                return;
            }
            while take_reply(tabs[0].page, head, text) {
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
        end_tabs(tabs, pages);
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
    var edit: u8[>..] = [];          // the address bar's text while it is typed in
    let T = UiText { notes: notes, edit: edit };
    // Its text is mostly what it was, each time it is laid out.
    tp_text_cache(SHAPE_CACHE);
    var U = Ui { w: WINDOW_W, h: WINDOW_H, lights: 0.0, cur: 0, dev: dev, dev_tab: dev_tab,
                 oil: 0.0, mac_used: 0.0, mac_total: 0.0, cpu: 0.0, mac_cpu: 0.0, fps: 0, running: false,
                 back: false, forward: false, editing: false, caret: 0, all: false };
    weigh(U);
    var slot = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var actions: f32[>..<] = [];     // what clicks on the interface do: x, y, w, h and an ACT_ each

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
        else { first_ms = show_ui(F, U, tabs, T, 0.0, scale, slot, actions); }
        post(tabs[0].page, MSG_SIZE, slot.w, slot.h, scale);
        wait_for_frame(tabs, notes);
        let page_h = tabs[0].info.height;
        let y = clamp_scroll(at, page_h, slot.h);
        place_tab(0, true, y, slot);
        var bg = tabs[0].info.background;
        if !bare {
            weigh(U);
            show_ui(F, U, tabs, T, first_ms, scale, slot, actions);
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
        end_tabs(tabs, pages);
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
    weigh(U);

    var worker: i64 = -1;
    if mode == MODE_WAKE_TEST { worker = thread_spawn_contained(wake_after, 300, 42); }

    var scale: f32 = 0.0;
    var woken = false;
    var pointer_x: f32 = -1.0;       // where the pointer is over the content, or -1 off it
    var pointer_y: f32 = -1.0;
    var press_x: f32 = -1.0;         // where the last button went down, which, and with what keys
    var press_y: f32 = -1.0;
    var press_button: i32 = -1;
    var press_mods: i64 = 0;
    var head = ReplyHead { kind: 0, value: 0, len: 0 };
    var text: u8[>..<] = [];
    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var ui_ms: f32 = 0.0;            // what laying the interface out took last
    var sized = Rect { x: 0.0, y: 0.0, w: -1.0, h: -1.0 };   // the slot the tabs were laid out for
    var sized_scale: f32 = 0.0;      // and the backing scale
    var last_step: i64 = 0;          // the boar's last step
    // The window's line: frames drawn for what changed on screen since it
    // was measured, when it was, and the CPU time then, Tusk's and the
    // whole Mac's (busy and in all, in ticks).
    var content_frames: i64 = 0;
    var tick_from = clock_ns();
    var cpu_from = tp_cpu_ns();
    var mac_busy: i64 = 0;
    var mac_ticks: i64 = 0;
    mac_load(mac_busy, mac_ticks);
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
            let due = if U.running { STEP_MS - (ms(last_step, now) as i64) } else { RUN_AFTER_MS - (ms(t.opened, now) as i64) };
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
                } else if e.kind == EV_FRAME && tab_of(tabs, e.code) >= 0 {
                    // A hidden tab's display list waits in its mailbox, the
                    // latest replacing the one before, until the tab is shown:
                    // the main thread builds what it shows, and the GPU holds
                    // no more. A page left behind draws nothing.
                    let k = tab_of(tabs, e.code);
                    if k == U.cur {
                        let first = !tabs[k].ready;
                        if take_frame(tabs, k) {
                            arrived = true;
                            if first { redo = true; }
                        }
                    } else {
                        tabs[k].waiting = true;
                    }
                } else if e.kind == EV_REPLY && tab_of(tabs, e.code) < 0 {
                    reap(pages, e.code, head, text);
                } else if e.kind == EV_REPLY {
                    let k = tab_of(tabs, e.code);
                    var shape: i32 = -1;
                    var titled = false;
                    var follow = Follow { kind: FOLLOW_NONE, y: 0, at: 0, len: 0 };
                    if read_replies(tabs, k, notes, head, text, shape, titled, follow) && k == U.cur { redo = true; }
                    if k == U.cur && shape >= 0 { cursor = shape; }
                    if k == U.cur && titled { tp_set_title(title_of(tabs[k], T)); }
                    if follow.kind != FOLLOW_NONE {
                        // Where a link leads, as a tab is: a file's URL is its path.
                        var loc: u8[>..] = [];
                        as_loc(notes[follow.at..follow.at + follow.len], loc);
                        let at = notes.len;
                        notes.append(loc);
                        if follow.kind == FOLLOW_NEW_TAB {
                            open_tab(tabs, entries, notes, at, loc.len, pages, slot, scale);
                        } else if follow.kind == FOLLOW_JUMP {
                            push_entry(tabs, k, entries, at, loc.len);
                            tabs[k].loc_at = at;
                            tabs[k].loc_len = loc.len;
                            if follow.y >= 0 { tabs[k].scroll = follow.y; }
                        } else {
                            push_entry(tabs, k, entries, at, loc.len);
                            load(tabs, k, notes, at, loc.len, -1.0, false, pages, slot, scale);
                            if k == U.cur { tp_set_title(title_of(tabs[k], T)); }
                        }
                        redo = true;
                    }
                } else if e.kind == EV_MOUSE {
                    press_x = e.x as f32;
                    press_y = e.y as f32;
                    press_button = e.code;
                    press_mods = e.w as i64;
                    // A press anywhere else leaves the address bar as it was.
                    if U.editing && action_at(actions[..], press_x, press_y) != ACT_ADDRESS {
                        U.editing = false;
                        redo = true;
                    }
                } else if e.kind == EV_MOUSE_UP {
                    // A click: up where it went down. On the page, it asks the
                    // page what is there (a link with ⌘ or the middle button
                    // opens in a new tab); on the interface, it does what the
                    // element there says.
                    let x = e.x as f32;
                    let y = e.y as f32;
                    let clicked = e.code == press_button && abs(x - press_x) < CLICK_SLOP && abs(y - press_y) < CLICK_SLOP;
                    let new_tab = (press_mods & MOD_COMMAND) != 0 || e.code == 2;
                    if clicked && (e.code == 0 || e.code == 2) && in_slot(x, y, slot) && tabs[U.cur].ready {
                        post(tabs[U.cur].page, MSG_CLICK, x - slot.x, y - slot.y + tabs[U.cur].scroll, if new_tab { 1.0 } else { 0.0 });
                    } else if clicked && e.code == 0 {
                        let act = action_at(actions[..], x, y);
                        if act == ACT_BACK { go(tabs, U.cur, entries, entries[tabs[U.cur].entry].prev, notes, pages, slot, scale); }
                        else if act == ACT_FORWARD { go(tabs, U.cur, entries, entries[tabs[U.cur].entry].next, notes, pages, slot, scale); }
                        else if act == ACT_RELOAD { reload(tabs, U.cur, notes, pages, slot, scale, false); }
                        else if act == ACT_ADDRESS && !U.editing {
                            var here: u8[>..] = [];
                            here.append(loc_of(tabs[U.cur], T));
                            start_typing(U, edit, here[..]);
                        }
                        if act != ACT_NONE { redo = true; }
                    }
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
                    let cmd = (mods & MOD_COMMAND) != 0;
                    var typed = false;           // the address bar took the key
                    if U.editing { typed = type_key(U, edit, e.code, cmd); }
                    if typed { redo = true; }
                    else if U.editing && (e.code == KEY_RETURN || e.code == KEY_ENTER) {
                        // Where the text leads, in this tab or with ⌘ a new one.
                        var loc: u8[>..] = [];
                        if typed_loc(edit[..], loc) {
                            U.editing = false;
                            let at = notes.len;
                            notes.append(loc);
                            if cmd {
                                open_tab(tabs, entries, notes, at, loc.len, pages, slot, scale);
                                U.cur = tabs.len - 1;
                            } else {
                                push_entry(tabs, U.cur, entries, at, loc.len);
                                load(tabs, U.cur, notes, at, loc.len, -1.0, false, pages, slot, scale);
                                tp_set_title(title_of(tabs[U.cur], T));
                            }
                        }
                        redo = true;
                    }
                    else if cmd && e.code == KEY_L {
                        var here: u8[>..] = [];
                        here.append(loc_of(tabs[U.cur], T));
                        start_typing(U, edit, here[..]);
                        redo = true;
                    }
                    else if cmd && (e.code == KEY_Q || e.code == KEY_W) { quit = true; }
                    else if cmd && (e.code == KEY_LEFT_BRACKET || e.code == KEY_LEFT) {
                        go(tabs, U.cur, entries, entries[tabs[U.cur].entry].prev, notes, pages, slot, scale);
                        redo = true;
                    }
                    else if cmd && (e.code == KEY_RIGHT_BRACKET || e.code == KEY_RIGHT) {
                        go(tabs, U.cur, entries, entries[tabs[U.cur].entry].next, notes, pages, slot, scale);
                        redo = true;
                    }
                    else if cmd && e.code == KEY_R {
                        reload(tabs, U.cur, notes, pages, slot, scale, (mods & MOD_SHIFT) != 0);
                        redo = true;
                    }
                    else if e.code == KEY_ESCAPE && !tabs[U.cur].ready && !tabs[U.cur].failed {
                        // Esc stops a load: its page is let go, and the tab says so.
                        retire(tabs, U.cur, pages);
                        tabs[U.cur].failed = true;
                        tabs[U.cur].why_at = notes.len;
                        notes.append("Stopped");
                        tabs[U.cur].why_len = 7;
                        redo = true;
                    }
                    else if (mods & MOD_COMMAND) != 0 && (mods & MOD_OPTION) != 0 && e.code == KEY_I {
                        // ⌘⌥I hides the dev panel, and the page takes its room; again, it shows.
                        U.dev = !U.dev;
                        redo = true;
                    }
                    else if (mods & MOD_COMMAND) != 0 && (mods & MOD_SHIFT) != 0 && e.code == KEY_S {
                        // A page Tusk can't show yet opens in Safari (docs/adr/0001).
                        var url: u8[>..] = [];
                        let loc = loc_of(tabs[U.cur], T);
                        if !is_web(loc) { url.append("file://"); }
                        url.append(loc);
                        tp_open_in_safari(url[..]);
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
            tp_set_title(title_of(tabs[U.cur], T));
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
            // As a share of the whole Mac: one busy core of 15 is 6.7%.
            let load = ((cpu - cpu_from) / 10000000.0 / secs / max(tp_cores(), 1)) as f32;
            let mac = mac_load(mac_busy, mac_ticks);
            let was = U;
            weigh(U);
            if fps != U.fps || abs(load - U.cpu) >= 0.1 || abs(mac - U.mac_cpu) >= 0.1 || weighs_else(was, U) {
                U.fps = fps;
                U.cpu = load;
                U.mac_cpu = mac;
                redo = true;
                drawn_line = true;
            }
            ticking = fps > 0;
            tick_from = now;
            cpu_from = cpu;
            content_frames = 0;
        }
        // Drawing allocates memory the system only settles later: a while
        // after the last frame the oil is weighed again, once, and the CPU,
        // which was last measured while frames still came.
        if settle && ms(settle_at, clock_ns()) >= SETTLE_MS {
            settle = false;
            let now = clock_ns();
            let cpu = tp_cpu_ns();
            let load = ((cpu - cpu_from) / 10000000.0 / (ms(tick_from, now) / 1000.0) / max(tp_cores(), 1)) as f32;
            let mac = mac_load(mac_busy, mac_ticks);
            let was = U;
            weigh(U);
            if weighs_else(was, U) || abs(load - U.cpu) >= 0.1 || abs(mac - U.mac_cpu) >= 0.1 {
                U.cpu = load;
                U.mac_cpu = mac;
                redo = true;
                drawn_line = true;
            }
            tick_from = now;
            cpu_from = cpu;
        }
        if redo && U.w > 0.0 && scale > 0.0 {
            let place = tabs[U.cur].entry;
            U.back = place >= 0 && entries[place].prev >= 0;
            U.forward = place >= 0 && entries[place].next >= 0;
            ui_ms = show_ui(F, U, tabs, T, ui_ms, scale, slot, actions);
            // Every tab lays out again for a new slot at once, each on its own
            // core, so showing another is instant.
            // And for a new backing scale: a display list carries the scale
            // it was made for.
            if slot.w != sized.w || slot.h != sized.h || scale != sized_scale {
                for t in tabs { post(t.page, MSG_SIZE, slot.w, slot.h, scale); }
                sized = slot;
                sized_scale = scale;
            }
        }
        // His next step, every STEP_MS whatever else happens meanwhile.
        var stepped = false;
        if U.running && scale > 0.0 && (redo || ms(last_step, clock_ns()) >= STEP_MS) {
            show_loader(F, U, U.cur, ms(shown.opened, clock_ns()) as f32 / 1000.0, scale);
            last_step = clock_ns();
            stepped = true;
        }
        tabs[U.cur].scroll = clamp_scroll(tabs[U.cur].scroll, tabs[U.cur].info.height, slot.h);
        let scrolled = tabs[U.cur].scroll != before;
        // A frame only when what is on screen changed.
        if redo || arrived || scrolled || stepped {
            if tabs[U.cur].ready { place_tab(U.cur, true, tabs[U.cur].scroll, slot); }
            tp_render(STEEL);
            // The window line's own frames aren't what it counts, nor what
            // the oil settles after.
            if !drawn_line || arrived || scrolled || switched {
                settle = true;
                settle_at = clock_ns();
                content_frames += 1;
                if !ticking {
                    ticking = true;
                    tick_from = clock_ns();
                    cpu_from = tp_cpu_ns();
                    mac_load(mac_busy, mac_ticks);
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
                post(tabs[U.cur].page, MSG_HIT, pointer_x - slot.x, pointer_y - slot.y + tabs[U.cur].scroll, 0.0);
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
    weight(tabs[U.cur], T, ui_ms, line);
    print(line);
    print("frames presented: ", tp_frames());
    tp_close();
    end_tabs(tabs, pages);
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

// The address bar is typed in, starting from where the tab is, all of it
// selected.
fn start_typing(U: Ui&, edit: u8[>..]&, loc: const u8[:]) {
    edit = [];
    edit.append(loc);
    U.editing = true;
    U.caret = edit.len;
    U.all = true;
}

// What key `code` (⌘ held: `cmd`) does to the address bar's text `edit`:
// Esc leaves it as it was; ⌫ and ⌦ delete; ←, →, ⌘←, ⌘→, Home and End move
// the caret; ⌘A selects all; ⌘C copies all, ⌘X cuts all, ⌘V pastes; and a
// key that types, types. True if it took the key: Return, and ⌘ with the
// rest, are left to the window.
fn type_key(U: Ui&, edit: u8[>..]&, code: i32, cmd: bool) -> bool {
    if code == KEY_ESCAPE { U.editing = false; return true; }
    if code == KEY_DELETE || code == KEY_FORWARD_DELETE {
        if U.all { edit = []; U.caret = 0; U.all = false; return true; }
        if code == KEY_DELETE && U.caret > 0 {
            let b = char_before(edit[..], U.caret);
            let left = spliced(edit[..], b, U.caret, "");
            edit = copy(left);
            U.caret = b;
        } else if code == KEY_FORWARD_DELETE && U.caret < edit.len {
            let left = spliced(edit[..], U.caret, char_after(edit[..], U.caret), "");
            edit = copy(left);
        }
        return true;
    }
    if code == KEY_LEFT || code == KEY_HOME {
        U.caret = if U.all || cmd || code == KEY_HOME { 0 } else { char_before(edit[..], U.caret) };
        U.all = false;
        return true;
    }
    if code == KEY_RIGHT || code == KEY_END {
        U.caret = if U.all || cmd || code == KEY_END { edit.len } else { char_after(edit[..], U.caret) };
        U.all = false;
        return true;
    }
    if cmd && code == KEY_A { U.all = true; return true; }
    if cmd && (code == KEY_C || code == KEY_X) {
        tp_copy(edit[..]);
        if code == KEY_X { edit = []; U.caret = 0; U.all = false; }
        return true;
    }
    var text: u8[>..] = [];
    if cmd && code == KEY_V {
        let n = tp_paste(text[..]);
        guard n > 0 else { return true; }
        for i in n { text.push(0); }
        guard tp_paste(text[..]) == n else { return true; }
        let line = one_line_of(text[..]);
        text = copy(line);
    } else if !cmd {
        let n = tp_key_text(text[..]);
        guard n > 0 else { return code != KEY_RETURN && code != KEY_ENTER; }
        for i in n { text.push(0); }
        guard tp_key_text(text[..]) == n else { return true; }
    } else {
        return false;
    }
    if U.all {
        edit = copy(text);
        U.caret = edit.len;
        U.all = false;
    } else {
        let typed = spliced(edit[..], U.caret, U.caret, text[..]);
        edit = copy(typed);
        U.caret += text.len;
    }
    return true;
}

// Weighs the window's oil and the Mac's memory into U, in MB.
fn weigh(U: Ui&) {
    U.oil = tp_memory_footprint() / 1048576.0;
    var total: i64 = 0;
    var used: i64 = 0;
    if tp_mac_memory(total, used) == 0 {
        U.mac_total = total / 1048576.0;
        U.mac_used = used / 1048576.0;
    }
}

// The whole Mac's CPU load since `busy` and `ticks` were read, in % of all
// its cores (Activity Monitor's System and User together); reads them again.
fn mac_load(busy: i64&, ticks: i64&) -> f32 {
    var b: i64 = 0;
    var t: i64 = 0;
    guard tp_mac_cpu(b, t) == 0 else { return 0.0; }
    let load = if t > ticks { ((b - busy) * 100.0 / (t - ticks)) as f32 } else { 0.0 };
    busy = b;
    ticks = t;
    return load;
}

// Whether the readout's weights differ enough to show: Tusk's by 0.1 MB, as
// it is written, and the Mac's by 0.1 GB.
fn weighs_else(a: Ui, b: Ui) -> bool {
    return abs(a.oil - b.oil) >= 0.1 || abs(a.mac_used - b.mac_used) >= 102.4 || a.mac_total != b.mac_total;
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
fn weight(t: Tab, T: UiText, ui_ms: f32, line: u8[>..]&) {
    format(line, name_of(t, T), "  ");
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

// Tells every tab's page to quit, waits for its worker and closes its
// mailbox, and those of the pages left behind. A worker that failed says why.
fn end_tabs(tabs: Tab[>..]&, pages: Pages&) {
    for t in tabs { post(t.page, MSG_QUIT, 0.0, 0.0, 0.0); }
    for t, k in tabs {
        guard t.worker >= 0 else { continue; }
        var why: u8[>..] = [];
        if !thread_wait(t.worker, why) { write_stderr(str("tusk: tab ", k, " failed: ", why, "\n")); }
        tp_tab_drop(t.page);
    }
    for id, j in pages.ids {
        guard id >= 0 else { continue; }
        var why: u8[>..] = [];
        thread_wait(pages.workers[j], why);
        tp_tab_drop(id);
    }
}

// Opens a tab for where the span `at`, `len` of the notes says, at the end,
// in layer `tabs.len`; none past MAX_TABS.
fn open_tab(tabs: Tab[>..]&, entries: Entry[>..]&, notes: const u8[:], at: i64, len: i64, pages: Pages&, slot: Rect,
            scale: f32) {
    guard tabs.len < MAX_TABS else { return; }
    let info = FrameInfo { height: 0.0, background: 0xFFFFFFFF, nodes: 0, bytes: 0, parse: 0.0, style: 0.0,
                           measure: 0.0, layout: 0.0, scale: 1.0, read: 0.0 };
    tabs.push(Tab { worker: -1, page: -1, ready: false, failed: false, info: info, paint: 0.0, waiting: false,
                    scroll: 0.0, restore: -1.0, opened: clock_ns(), load_ms: 0.0, status: 0, entry: -1, loc_at: at,
                    loc_len: len, title_at: 0, title_len: 0, why_at: 0, why_len: 0, log_at: 0, log_len: 0,
                    elems_at: 0, elems_len: 0 });
    let k = tabs.len - 1;
    push_entry(tabs, k, entries, at, len);
    load(tabs, k, notes, at, len, -1.0, false, pages, slot, scale);
}

// Loads tab k's page again where it is, past the cache when `hard` says so,
// and scrolls back to where it was once it comes.
fn reload(tabs: Tab[>..]&, k: i64, notes: const u8[:], pages: Pages&, slot: Rect, scale: f32, hard: bool) {
    let back_to = tabs[k].scroll;
    load(tabs, k, notes, tabs[k].loc_at, tabs[k].loc_len, back_to, hard, pages, slot, scale);
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
            let k = if e.kind == EV_FRAME { tab_of(tabs, e.code) } else { -1 };
            if k == cur { take_frame(tabs, cur); }
            else if k >= 0 { tabs[k].waiting = true; }
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
