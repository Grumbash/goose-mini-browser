//! Tab workers' mailboxes (docs/adr/0010). Each page runs in a Goose worker
//! that owns its document. The main thread posts a tab messages: its size, a
//! point to hit test, a snapshot request, quit. The worker posts back display
//! lists and replies, and the main thread hears of each as an event. Neither
//! side spins: a worker sleeps until its inbox has something, and the main
//! thread until AppKit hands it an event, or here without a window.
//!
//! What only the latest of matters is kept once: a new size or hit test
//! replaces one still in the inbox, a new display list one not yet shown, and
//! a new hit's reply one not yet read. A drag that resizes the window sends
//! a tab one size at a time, however fast it goes.

use std::collections::{HashMap, VecDeque};
use std::sync::{Condvar, LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::compositor::{DItem, MAX_LAYERS, with_compositor};
use crate::{ERR_ARGUMENT, GSlice, guarded, on_main_thread};

/// A message to a tab, laid out as Goose's `struct TabMsg`.
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TabMsg {
    pub kind: i32,
    pub a: f32,
    pub b: f32,
    pub c: f32,
}

// Message kinds; the Goose side mirrors these numbers.
pub const MSG_SIZE: i32 = 1; // a: width, b: the view's height, c: backing scale
pub const MSG_HIT: i32 = 2; // a, b: a point on the page
pub const MSG_SNAPSHOT: i32 = 3;
pub const MSG_QUIT: i32 = 4;

/// What a tab's display list came with, laid out as Goose's `struct
/// FrameInfo`: the page's height, its canvas colour, its size in nodes and
/// bytes, and what each stage of showing it took, in milliseconds.
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, Default)]
pub struct FrameInfo {
    pub height: f32,
    pub background: u32,
    pub nodes: i32,
    pub bytes: i32,
    pub parse: f32,
    pub style: f32,
    pub measure: f32,
    pub layout: f32,
    pub scale: f32,
}

/// A reply waiting for the main thread, as Goose's `struct ReplyHead` sees
/// it: its kind, a number, and how many bytes of text come with it.
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ReplyHead {
    pub kind: i32,
    pub value: i32,
    pub len: i64,
}

// Reply kinds; the Goose side mirrors these numbers.
pub const REPLY_HIT: i32 = 1; // value: the pointer shape over the point
pub const REPLY_TITLE: i32 = 2; // text: the page's title
pub const REPLY_SNAPSHOT: i32 = 3; // text: the page as a tree for agents
pub const REPLY_FAILED: i32 = 4; // text: why the page didn't load

struct Frame {
    items: Vec<DItem>,
    text: Vec<u8>,
    paths: Vec<f32>,
    info: FrameInfo,
}

struct Reply {
    kind: i32,
    value: i32,
    text: Vec<u8>,
}

#[derive(Default)]
struct Tab {
    inbox: VecDeque<TabMsg>,
    frame: Option<Frame>,
    replies: VecDeque<Reply>,
}

static TABS: LazyLock<Mutex<HashMap<i32, Tab>>> = LazyLock::new(Default::default);
/// Signalled when an inbox gets a message: the workers wait on it.
static TO_TABS: Condvar = Condvar::new();
/// Signalled when a frame or a reply is posted: the main thread waits on it
/// when it has no window.
static TO_MAIN: Condvar = Condvar::new();

fn tabs() -> MutexGuard<'static, HashMap<i32, Tab>> {
    // A worker that panicked can't have left a tab half written: every
    // change here is a single push or replace.
    TABS.lock().unwrap_or_else(|e| e.into_inner())
}

/// Opens tab `tab`'s mailbox, before its worker starts.
#[unsafe(no_mangle)]
pub extern "C" fn tp_tab_open(tab: i32) -> i32 {
    guarded(|| {
        tabs().insert(tab, Tab::default());
        Ok(0)
    })
}

/// Closes tab `tab`'s mailbox, once its worker has ended; what was still in
/// it goes too.
#[unsafe(no_mangle)]
pub extern "C" fn tp_tab_drop(tab: i32) -> i32 {
    guarded(|| {
        tabs().remove(&tab).ok_or(ERR_ARGUMENT)?;
        Ok(0)
    })
}

/// Posts `msg` to tab `tab`'s worker. A size or a hit test replaces one of
/// its kind still waiting.
#[unsafe(no_mangle)]
pub extern "C" fn tp_tab_post(tab: i32, msg: *const TabMsg) -> i32 {
    guarded(|| {
        if msg.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let m = unsafe { msg.read_unaligned() };
        let mut tabs = tabs();
        let t = tabs.get_mut(&tab).ok_or(ERR_ARGUMENT)?;
        post(&mut t.inbox, m);
        TO_TABS.notify_all();
        Ok(0)
    })
}

/// Queues `m`, replacing a size or a hit test of its kind still waiting.
fn post(inbox: &mut VecDeque<TabMsg>, m: TabMsg) {
    if m.kind == MSG_SIZE || m.kind == MSG_HIT {
        let kind = m.kind;
        if let Some(waiting) = inbox.iter_mut().find(|w| w.kind == kind) {
            *waiting = m;
            return;
        }
    }
    inbox.push_back(m);
}

/// In tab `tab`'s worker: waits up to `timeout_ms` (forever below 0) for the
/// next message and writes it to `out`. Returns 1 with a message, 0 on a
/// timeout.
#[unsafe(no_mangle)]
pub extern "C" fn tp_tab_next(tab: i32, timeout_ms: i64, out: *mut TabMsg) -> i32 {
    guarded(|| {
        if out.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let until =
            (timeout_ms >= 0).then(|| Instant::now() + Duration::from_millis(timeout_ms as u64));
        let mut tabs = tabs();
        loop {
            let t = tabs.get_mut(&tab).ok_or(ERR_ARGUMENT)?;
            if let Some(m) = t.inbox.pop_front() {
                unsafe { out.write_unaligned(m) };
                return Ok(1);
            }
            tabs = match until {
                None => TO_TABS.wait(tabs).unwrap_or_else(|e| e.into_inner()),
                Some(until) => {
                    let left = until.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Ok(0);
                    }
                    TO_TABS
                        .wait_timeout(tabs, left)
                        .unwrap_or_else(|e| e.into_inner())
                        .0
                }
            };
        }
    })
}

/// In tab `tab`'s worker: hands over a display list (see tp_set_layer) and
/// what came with it. It replaces one the main thread hasn't shown yet, and
/// only the first of those wakes it.
#[unsafe(no_mangle)]
pub extern "C" fn tp_post_frame(
    tab: i32,
    items: GSlice<DItem>,
    text: GSlice<u8>,
    paths: GSlice<f32>,
    info: *const FrameInfo,
) -> i32 {
    guarded(|| {
        if info.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let items = unsafe { items.as_slice() }.ok_or(ERR_ARGUMENT)?.to_vec();
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?.to_vec();
        // Goose's floats needn't be aligned: copied out one by one.
        let n = paths.count().ok_or(ERR_ARGUMENT)?;
        let paths: Vec<f32> = (0..n).map(|i| unsafe { paths.get(i) }).collect();
        let info = unsafe { info.read_unaligned() };
        let wake = {
            let mut tabs = tabs();
            let t = tabs.get_mut(&tab).ok_or(ERR_ARGUMENT)?;
            let first = t.frame.is_none();
            t.frame = Some(Frame {
                items,
                text,
                paths,
                info,
            });
            first
        };
        if wake {
            TO_MAIN.notify_all();
            crate::post_to_main(crate::EV_FRAME, tab);
        }
        Ok(0)
    })
}

/// In tab `tab`'s worker: posts a reply of `kind` with `value` and `text`. A
/// hit's reply replaces one the main thread hasn't read.
#[unsafe(no_mangle)]
pub extern "C" fn tp_post_reply(tab: i32, kind: i32, value: i32, text: GSlice<u8>) -> i32 {
    guarded(|| {
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?.to_vec();
        {
            let mut tabs = tabs();
            let t = tabs.get_mut(&tab).ok_or(ERR_ARGUMENT)?;
            let reply = Reply { kind, value, text };
            match t
                .replies
                .iter_mut()
                .find(|r| r.kind == REPLY_HIT && kind == REPLY_HIT)
            {
                Some(waiting) => *waiting = reply,
                None => t.replies.push_back(reply),
            }
        }
        TO_MAIN.notify_all();
        crate::post_to_main(crate::EV_REPLY, tab);
        Ok(0)
    })
}

/// On the main thread: puts tab `tab`'s waiting display list in layer
/// `layer`, without copying it again, and writes what came with it to
/// `info`. Returns 1 with a list, 0 when none was waiting.
#[unsafe(no_mangle)]
pub extern "C" fn tp_take_frame(tab: i32, layer: i32, info: *mut FrameInfo) -> i32 {
    guarded(|| {
        on_main_thread()?;
        if info.is_null() || !(0..MAX_LAYERS as i32).contains(&layer) {
            return Err(ERR_ARGUMENT);
        }
        let frame = tabs().get_mut(&tab).ok_or(ERR_ARGUMENT)?.frame.take();
        let Some(f) = frame else {
            return Ok(0);
        };
        let scale = f.info.scale as f64;
        if !(scale > 0.0 && scale <= 8.0) {
            return Err(ERR_ARGUMENT);
        }
        unsafe { info.write_unaligned(f.info) };
        with_compositor(|c| c.set_layer_owned(layer as usize, f.items, f.text, f.paths, scale))?;
        Ok(1)
    })
}

/// On the main thread: writes the head of tab `tab`'s first waiting reply
/// to `out`. Returns 1 with one, 0 with none.
#[unsafe(no_mangle)]
pub extern "C" fn tp_reply_head(tab: i32, out: *mut ReplyHead) -> i32 {
    guarded(|| {
        if out.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let tabs = tabs();
        let t = tabs.get(&tab).ok_or(ERR_ARGUMENT)?;
        let Some(r) = t.replies.front() else {
            return Ok(0);
        };
        let head = ReplyHead {
            kind: r.kind,
            value: r.value,
            len: r.text.len() as i64,
        };
        unsafe { out.write_unaligned(head) };
        Ok(1)
    })
}

/// On the main thread: takes tab `tab`'s first waiting reply, copying its
/// text into `text`, which tp_reply_head said how long to make.
#[unsafe(no_mangle)]
pub extern "C" fn tp_take_reply(tab: i32, text: GSlice<u8>) -> i32 {
    guarded(|| {
        let n = text.count().ok_or(ERR_ARGUMENT)?;
        let mut tabs = tabs();
        let t = tabs.get_mut(&tab).ok_or(ERR_ARGUMENT)?;
        let r = t.replies.front().ok_or(ERR_ARGUMENT)?;
        if r.text.len() != n {
            return Err(ERR_ARGUMENT);
        }
        for (i, &b) in r.text.iter().enumerate() {
            unsafe { text.set(i, b) };
        }
        t.replies.pop_front();
        Ok(0)
    })
}

/// With no window: waits up to `timeout_ms` (forever below 0) for tab `tab`
/// to post a display list or a reply. Returns 1 for a list, 2 for a reply,
/// 0 on a timeout. A window's main thread hears of them as events instead.
#[unsafe(no_mangle)]
pub extern "C" fn tp_wait_tab(tab: i32, timeout_ms: i64) -> i32 {
    guarded(|| {
        let until =
            (timeout_ms >= 0).then(|| Instant::now() + Duration::from_millis(timeout_ms as u64));
        let mut tabs = tabs();
        loop {
            let t = tabs.get(&tab).ok_or(ERR_ARGUMENT)?;
            if t.frame.is_some() {
                return Ok(1);
            }
            if !t.replies.is_empty() {
                return Ok(2);
            }
            tabs = match until {
                None => TO_MAIN.wait(tabs).unwrap_or_else(|e| e.into_inner()),
                Some(until) => {
                    let left = until.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Ok(0);
                    }
                    TO_MAIN
                        .wait_timeout(tabs, left)
                        .unwrap_or_else(|e| e.into_inner())
                        .0
                }
            };
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structs_match_the_goose_layout() {
        assert_eq!(std::mem::size_of::<TabMsg>(), 16);
        assert_eq!(std::mem::size_of::<FrameInfo>(), 36);
        assert_eq!(std::mem::size_of::<ReplyHead>(), 16);
    }

    #[test]
    fn only_the_latest_size_and_hit_wait() {
        let msg = |kind, a| TabMsg {
            kind,
            a,
            ..Default::default()
        };
        let mut inbox = VecDeque::new();
        post(&mut inbox, msg(MSG_SIZE, 100.0));
        post(&mut inbox, msg(MSG_HIT, 1.0));
        post(&mut inbox, msg(MSG_SIZE, 200.0));
        post(&mut inbox, msg(MSG_SNAPSHOT, 0.0));
        post(&mut inbox, msg(MSG_HIT, 2.0));
        post(&mut inbox, msg(MSG_SNAPSHOT, 0.0));
        let got: Vec<(i32, f32)> = inbox.iter().map(|m| (m.kind, m.a)).collect();
        assert_eq!(
            got,
            [
                (MSG_SIZE, 200.0),
                (MSG_HIT, 2.0),
                (MSG_SNAPSHOT, 0.0),
                (MSG_SNAPSHOT, 0.0)
            ]
        );
    }

    #[test]
    fn a_worker_waits_for_its_message_and_the_main_thread_for_a_frame() {
        let tab = 9001;
        assert_eq!(tp_tab_open(tab), 0);
        let worker = std::thread::spawn(move || {
            let mut m = TabMsg::default();
            assert_eq!(tp_tab_next(tab, 5000, &mut m), 1);
            let (kind, a) = (m.kind, m.a);
            assert_eq!((kind, a), (MSG_SIZE, 640.0));
            let info = FrameInfo {
                height: 1234.0,
                scale: 2.0,
                ..Default::default()
            };
            let none = GSlice::<DItem> {
                data: std::ptr::null_mut(),
                len: 0,
            };
            let no_text = GSlice::<u8> {
                data: std::ptr::null_mut(),
                len: 0,
            };
            let no_paths = GSlice::<f32> {
                data: std::ptr::null_mut(),
                len: 0,
            };
            assert_eq!(tp_post_frame(tab, none, no_text, no_paths, &info), 0);
            // With nothing else posted, a short wait times out.
            assert_eq!(tp_tab_next(tab, 10, &mut m), 0);
        });
        let size = TabMsg {
            kind: MSG_SIZE,
            a: 640.0,
            b: 480.0,
            c: 2.0,
        };
        assert_eq!(tp_tab_post(tab, &size), 0);
        assert_eq!(tp_wait_tab(tab, 5000), 1);
        worker.join().unwrap();
        // The frame waits until the main thread takes it; a reply is read
        // by its head, then its text.
        let mut text = *b"title";
        let slice = GSlice {
            data: text.as_mut_ptr(),
            len: 5,
        };
        assert_eq!(tp_post_reply(tab, REPLY_TITLE, 0, slice), 0);
        let mut head = ReplyHead::default();
        assert_eq!(tp_reply_head(tab, &mut head), 1);
        let (kind, len) = (head.kind, head.len);
        assert_eq!((kind, len), (REPLY_TITLE, 5));
        let mut got = [0u8; 5];
        let into = GSlice {
            data: got.as_mut_ptr(),
            len: 5,
        };
        assert_eq!(tp_take_reply(tab, into), 0);
        assert_eq!(&got, b"title");
        assert_eq!(tp_reply_head(tab, &mut head), 0);
        assert_eq!(tp_tab_drop(tab), 0);
        assert_eq!(tp_tab_post(tab, &size), ERR_ARGUMENT);
    }

    #[test]
    fn a_hit_reply_replaces_the_one_not_read() {
        let tab = 9002;
        assert_eq!(tp_tab_open(tab), 0);
        let empty = GSlice::<u8> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        assert_eq!(tp_post_reply(tab, REPLY_HIT, 0, empty), 0);
        assert_eq!(tp_post_reply(tab, REPLY_HIT, 1, empty), 0);
        let mut head = ReplyHead::default();
        assert_eq!(tp_reply_head(tab, &mut head), 1);
        let value = head.value;
        assert_eq!(value, 1);
        assert_eq!(tp_take_reply(tab, empty), 0);
        assert_eq!(tp_reply_head(tab, &mut head), 0);
        assert_eq!(tp_tab_drop(tab), 0);
    }
}
