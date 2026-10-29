// M0 of the engine plan (docs/ENGINE.md): the Rust platform layer driven from
// Goose. Opens the window, sleeps until something happens, and draws only when
// the window needs a new frame. `--idle-exit MS` quits after MS of quiet, for
// the idle test in design/measurements/.

import std;
import os;

struct Event { kind: i32, code: i32, x: f64, y: f64, w: f64, h: f64 }

extern "goose_platform" {
    fn gp_open(width: f64, height: f64, title: const u8&, title_len: i64) -> i32;
    fn gp_next_event(timeout_ms: i64, out: Event&) -> i32;
    fn gp_present(r: f64, g: f64, b: f64) -> i32;
    fn gp_frames() -> i64;
    fn gp_close() -> i32;
    fn gp_wake(token: i64) -> i32;
}

// Event kinds, as numbered in platform/src/lib.rs.
let EV_NONE: i32 = 0;
let EV_CLOSE: i32 = 1;
let EV_RESIZE: i32 = 2;
let EV_KEY: i32 = 3;
let EV_WAKE: i32 = 6;
let KEY_ESCAPE: i32 = 53;

fn paint() -> i32 { return gp_present(0.96, 0.96, 0.97); }

// Stands in for a tab worker that has finished a frame: it wakes the sleeping
// main thread through the platform layer, the path every frame will take.
thread_fn wake_after(ms: i64, token: i64) {
    sleep_ms(ms);
    gp_wake(token);
}

fn main() {
    var idle_exit_ms: i64 = -1;
    var wake_test = false;
    let argv = args();
    if argv.len == 3 && argv[1] == "--idle-exit" {
        let n, ok = parse_int(argv[2]);
        if ok { idle_exit_ms = n; }
    }
    if argv.len == 2 && argv[1] == "--wake-test" {
        wake_test = true;
        idle_exit_ms = 5000;
    }

    let title = "goose";
    guard gp_open(960.0, 640.0, title[0], title.len) == 0 else {
        write_stderr("platform: could not open a window\n");
        return;
    }
    paint();

    var worker: i64 = -1;
    if wake_test { worker = thread_spawn_contained(wake_after, 300, 42); }

    var e = Event { kind: 0, code: 0, x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    loop {
        guard gp_next_event(idle_exit_ms, e) == 0 else { break; }
        if e.kind == EV_NONE { break; }     // only happens with --idle-exit
        if e.kind == EV_CLOSE { break; }
        if e.kind == EV_KEY && e.code == KEY_ESCAPE { break; }
        if e.kind == EV_RESIZE { paint(); }
        if e.kind == EV_WAKE {
            print("woken by a worker, token ", e.code);
            if wake_test { break; }
        }
    }
    if worker >= 0 { thread_wait(worker); }
    print("frames presented: ", gp_frames());
    gp_close();
}
