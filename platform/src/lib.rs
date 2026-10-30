//! tusk_platform: the Apple-silicon platform layer for Tusk.
//!
//! A window, input and a Metal surface, driven from Goose's main thread through
//! a C ABI. The main thread sleeps inside `tp_next_event` until something
//! happens, so an idle window costs no CPU and draws no frames.
//!
//! Every entry point catches panics and returns an error code: a panic must
//! never cross into Goose, where it would abort the whole process
//! (docs/adr/0001).
#![allow(unused_unsafe)]
// The entry points are C functions that Goose calls with pointers into its own
// memory; marking them `unsafe` would change nothing for that caller.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod cg;
pub mod compositor;
mod memory;
pub mod text;

use std::cell::RefCell;
use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};

use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSCursor, NSEvent,
    NSEventMask, NSEventModifierFlags, NSEventType, NSTrackingArea, NSTrackingAreaOptions,
    NSWindow, NSWindowStyleMask,
};
use objc2_core_foundation::CGSize;
use objc2_core_graphics::{CGColorSpace, kCGColorSpaceSRGB};
use objc2_foundation::{NSDate, NSDefaultRunLoopMode, NSPoint, NSRect, NSSize, NSString};
use objc2_metal::MTLPixelFormat;
use objc2_quartz_core::{CAMetalLayer, kCAGravityTopLeft};

use compositor::with_compositor;

// Error codes returned to Goose. Zero or positive means success.
pub(crate) const ERR_NOT_MAIN_THREAD: i32 = -1;
pub(crate) const ERR_NOT_OPEN: i32 = -2;
pub(crate) const ERR_METAL: i32 = -3;
pub(crate) const ERR_ARGUMENT: i32 = -4;
pub(crate) const ERR_NO_DEVICE: i32 = -5;
pub(crate) const ERR_PANIC: i32 = -100;

// Event kinds; the Goose side mirrors these numbers. Pointer positions are in
// points from the content's top left; modifier flags are AppKit's.
const EV_NONE: i32 = 0; // the wait timed out
const EV_CLOSE: i32 = 1;
const EV_RESIZE: i32 = 2; // w, h: content size in points; x: backing scale
const EV_KEY: i32 = 3; // code: macOS virtual key code; x: the modifier flags
const EV_MOUSE: i32 = 4; // a button went down: x, y; code: button (0 left, 1 right); w: modifiers; h: clicks
const EV_SCROLL: i32 = 5; // x, y: deltas; code: 1 for points (trackpads), 0 for lines (wheels); w, h: the pointer
const EV_WAKE: i32 = 6; // code: the token passed to tp_wake
const EV_MOUSE_UP: i32 = 7; // a button went up: as EV_MOUSE
const EV_MOUSE_MOVE: i32 = 8; // the pointer moved: x, y; code: buttons held (bit 0 left, bit 1 right); w: modifiers
const EV_MOUSE_LEAVE: i32 = 9; // the pointer left the content

/// One input event, laid out as Goose's `struct Event { kind: i32, code: i32,
/// x: f64, y: f64, w: f64, h: f64 }`.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct GpEvent {
    pub kind: i32,
    pub code: i32,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A Goose slice as it crosses into C: `{ data, len }` (Goose spec, appendix
/// C.2). Goose packs its values without alignment (spec §3.2), so elements may
/// sit at any address and are read and written unaligned.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GSlice<T> {
    pub data: *mut T,
    pub len: i64,
}

impl<T: Copy> GSlice<T> {
    /// The number of elements, or `None` for a malformed slice.
    pub fn count(&self) -> Option<usize> {
        if self.len < 0 || (self.data.is_null() && self.len > 0) {
            None
        } else {
            Some(self.len as usize)
        }
    }

    /// Element `i`.
    ///
    /// # Safety
    /// `i` is below `count()` and Goose's slice is valid for this call.
    pub unsafe fn get(&self, i: usize) -> T {
        unsafe { self.data.add(i).read_unaligned() }
    }

    /// Writes element `i`.
    ///
    /// # Safety
    /// `i` is below `count()` and Goose's slice is valid and writable for this call.
    pub unsafe fn set(&self, i: usize, v: T) {
        unsafe { self.data.add(i).write_unaligned(v) }
    }

    /// Borrows the elements of a type with alignment 1: bytes, and the packed
    /// structs that cross the boundary.
    ///
    /// # Safety
    /// Goose's slice is valid for this call; the borrow must not outlive it.
    pub unsafe fn as_slice<'a>(&self) -> Option<&'a [T]> {
        const { assert!(std::mem::align_of::<T>() == 1) };
        let n = self.count()?;
        if n == 0 {
            return Some(&[]);
        }
        Some(unsafe { std::slice::from_raw_parts(self.data, n) })
    }
}

struct Platform {
    app: Retained<NSApplication>,
    window: Retained<NSWindow>,
    layer: Retained<CAMetalLayer>,
    size: (f64, f64),
    scale: f64,
    refresh_hz: f64,
    open: bool,
    pending: VecDeque<GpEvent>,
    frames: i64,
    cursor: i32, // the CURSOR_ shape set last, or -1 when AppKit may have changed it
}

thread_local! {
    // AppKit objects live on the main thread only, so the state does too.
    static PLATFORM: RefCell<Option<Platform>> = const { RefCell::new(None) };
}

/// Runs `f`, turning a panic into ERR_PANIC so it never unwinds into Goose.
/// What Cocoa autoreleases during the call is released when it returns:
/// Tusk runs its own event loop, so no run loop drains a pool for it.
pub(crate) fn guarded(f: impl FnOnce() -> Result<i32, i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| autoreleasepool(|_| f()))) {
        Ok(Ok(code)) => code,
        Ok(Err(code)) => code,
        Err(_) => ERR_PANIC,
    }
}

fn with_platform(f: impl FnOnce(&mut Platform) -> Result<i32, i32>) -> Result<i32, i32> {
    MainThreadMarker::new().ok_or(ERR_NOT_MAIN_THREAD)?;
    PLATFORM.with(|cell| {
        let mut state = cell.borrow_mut();
        let p = state.as_mut().ok_or(ERR_NOT_OPEN)?;
        f(p)
    })
}

/// Opens the browser window with a Metal layer. Call once, on the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_open(width: f64, height: f64, title: *const u8, title_len: i64) -> i32 {
    guarded(|| {
        let mtm = MainThreadMarker::new().ok_or(ERR_NOT_MAIN_THREAD)?;
        if !(width > 0.0 && height > 0.0) || title_len < 0 || (title.is_null() && title_len > 0) {
            return Err(ERR_ARGUMENT);
        }
        let title = if title_len == 0 {
            String::new()
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(title, title_len as usize) };
            String::from_utf8_lossy(bytes).into_owned()
        };

        let app = NSApplication::sharedApplication(mtm);
        app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
        app.finishLaunching();

        let rect = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(width, height));
        let style = NSWindowStyleMask::Titled
            | NSWindowStyleMask::Closable
            | NSWindowStyleMask::Miniaturizable
            | NSWindowStyleMask::Resizable;
        let window = unsafe {
            NSWindow::initWithContentRect_styleMask_backing_defer(
                NSWindow::alloc(mtm),
                rect,
                style,
                NSBackingStoreType::Buffered,
                false,
            )
        };
        unsafe { window.setReleasedWhenClosed(false) };
        window.setTitle(&NSString::from_str(&title));
        window.center();

        let device = with_compositor(|c| Ok(c.device.clone()))?;
        let scale = window.backingScaleFactor();
        let layer = CAMetalLayer::new();
        unsafe {
            layer.setDevice(Some(&*device));
            layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
            layer.setFramebufferOnly(true);
            // Two drawables: the least memory and latency that still never
            // makes the CPU wait for the screen at 120 Hz.
            layer.setMaximumDrawableCount(2);
            layer.setOpaque(true);
            layer.setContentsScale(scale);
            layer.setDrawableSize(CGSize::new(width * scale, height * scale));
            // While the window is resized live, the last frame stays put
            // instead of stretching until the page is laid out again.
            layer.setContentsGravity(kCAGravityTopLeft);
            // Page colours are sRGB: tagging the layer makes the display
            // convert them, instead of showing them as its own wider P3.
            let srgb = CGColorSpace::with_name(Some(kCGColorSpaceSRGB));
            layer.setColorspace(srgb.as_deref());
        }
        let view = window.contentView().ok_or(ERR_ARGUMENT)?;
        // Layer-hosting view: the layer is set before wantsLayer.
        view.setLayer(Some(&**layer));
        view.setWantsLayer(true);
        // The pointer's moves and its leaving, whichever app is active: hover
        // follows the pointer as it does in other browsers.
        let tracking = unsafe {
            NSTrackingArea::initWithRect_options_owner_userInfo(
                NSTrackingArea::alloc(),
                NSRect::ZERO,
                NSTrackingAreaOptions::MouseEnteredAndExited
                    | NSTrackingAreaOptions::MouseMoved
                    | NSTrackingAreaOptions::ActiveAlways
                    | NSTrackingAreaOptions::InVisibleRect,
                Some(AsRef::<AnyObject>::as_ref(&*view)),
                None,
            )
        };
        view.addTrackingArea(&tracking);

        window.makeKeyAndOrderFront(None);
        app.activate();

        let refresh_hz = window
            .screen()
            .map_or(60.0, |s| s.maximumFramesPerSecond() as f64);
        // The first event is the window's size and scale, so the page is laid
        // out the same way on opening as after every resize.
        let mut pending = VecDeque::new();
        pending.push_back(GpEvent {
            kind: EV_RESIZE,
            x: scale,
            w: width,
            h: height,
            ..Default::default()
        });
        PLATFORM.with(|cell| {
            *cell.borrow_mut() = Some(Platform {
                app,
                window,
                layer,
                size: (width, height),
                scale,
                refresh_hz,
                open: true,
                pending,
                frames: 0,
                cursor: -1,
            })
        });
        Ok(0)
    })
}

/// Waits for the next event and writes it to `out`. `timeout_ms < 0` waits
/// forever; a timeout writes an EV_NONE event. The thread sleeps while waiting.
#[unsafe(no_mangle)]
pub extern "C" fn tp_next_event(timeout_ms: i64, out: *mut GpEvent) -> i32 {
    guarded(|| {
        if out.is_null() {
            return Err(ERR_ARGUMENT);
        }
        with_platform(|p| {
            let until = if timeout_ms < 0 {
                NSDate::distantFuture()
            } else {
                NSDate::dateWithTimeIntervalSinceNow(timeout_ms as f64 / 1000.0)
            };
            loop {
                if let Some(e) = p.pending.pop_front() {
                    unsafe { out.write_unaligned(e) };
                    return Ok(0);
                }
                // Events Tusk doesn't translate (mouse-ups, drags, gestures) are
                // consumed here too: release what each one autoreleases before
                // the next, rather than when the whole wait ends.
                let got = autoreleasepool(|_| {
                    let next = unsafe {
                        p.app.nextEventMatchingMask_untilDate_inMode_dequeue(
                            NSEventMask::Any,
                            Some(&until),
                            NSDefaultRunLoopMode,
                            true,
                        )
                    };
                    let Some(ev) = next else { return false };
                    let translated = translate(p, &ev);
                    // Our own wake events and key presses stop here: AppKit would
                    // beep at keys no responder handles.
                    let kind = ev.r#type();
                    if kind != NSEventType::ApplicationDefined && kind != NSEventType::KeyDown {
                        p.app.sendEvent(&ev);
                    }
                    check_window(p);
                    if let Some(e) = translated {
                        if e.kind == EV_MOUSE_LEAVE {
                            p.cursor = -1;
                        }
                        queue(&mut p.pending, e);
                    }
                    true
                });
                if !got {
                    unsafe {
                        out.write_unaligned(GpEvent {
                            kind: EV_NONE,
                            ..Default::default()
                        })
                    };
                    return Ok(0);
                }
            }
        })
    })
}

fn translate(p: &Platform, ev: &NSEvent) -> Option<GpEvent> {
    let kind = ev.r#type();
    if kind == NSEventType::ApplicationDefined {
        return Some(GpEvent {
            kind: EV_WAKE,
            code: ev.data1() as i32,
            ..Default::default()
        });
    }
    if kind == NSEventType::KeyDown {
        return Some(GpEvent {
            kind: EV_KEY,
            code: ev.keyCode() as i32,
            x: ev.modifierFlags().0 as f64,
            ..Default::default()
        });
    }
    let modifiers = ev.modifierFlags().0 as f64;
    let at = ev.locationInWindow();
    let (x, y) = (at.x, p.size.1 - at.y);
    if kind == NSEventType::MouseExited {
        return Some(GpEvent {
            kind: EV_MOUSE_LEAVE,
            ..Default::default()
        });
    }
    if kind == NSEventType::ScrollWheel {
        return Some(GpEvent {
            kind: EV_SCROLL,
            code: ev.hasPreciseScrollingDeltas() as i32,
            x: ev.scrollingDeltaX(),
            y: ev.scrollingDeltaY(),
            w: x,
            h: y,
        });
    }
    let (event, code) = pointer(kind)?;
    // A press in the title bar, above the content, is AppKit's alone.
    if event == EV_MOUSE && y < 0.0 {
        return None;
    }
    let clicks = if event == EV_MOUSE_MOVE {
        0.0
    } else {
        ev.clickCount() as f64
    };
    Some(GpEvent {
        kind: event,
        code,
        x,
        y,
        w: modifiers,
        h: clicks,
    })
}

/// The pointer event an AppKit mouse event is, and its code: the button, or
/// for a move the buttons held.
fn pointer(kind: NSEventType) -> Option<(i32, i32)> {
    Some(match kind {
        NSEventType::LeftMouseDown => (EV_MOUSE, 0),
        NSEventType::RightMouseDown => (EV_MOUSE, 1),
        NSEventType::LeftMouseUp => (EV_MOUSE_UP, 0),
        NSEventType::RightMouseUp => (EV_MOUSE_UP, 1),
        NSEventType::MouseMoved => (EV_MOUSE_MOVE, 0),
        NSEventType::LeftMouseDragged => (EV_MOUSE_MOVE, 1),
        NSEventType::RightMouseDragged => (EV_MOUSE_MOVE, 2),
        _ => return None,
    })
}

/// Adds event `e` to the ones waiting for Goose. A move replaces a move just
/// before it, and a scroll is added to a scroll of the same kind just before
/// it, so a burst of either costs Goose one hit test or one place a frame.
fn queue(pending: &mut VecDeque<GpEvent>, e: GpEvent) {
    if let Some(last) = pending.back_mut() {
        if e.kind == EV_MOUSE_MOVE && last.kind == EV_MOUSE_MOVE {
            *last = e;
            return;
        }
        if e.kind == EV_SCROLL && last.kind == EV_SCROLL && e.code == last.code {
            last.x += e.x;
            last.y += e.y;
            last.w = e.w;
            last.h = e.h;
            return;
        }
    }
    pending.push_back(e);
}

/// After AppKit has handled an event: notice a closed window or a new size.
fn check_window(p: &mut Platform) {
    // A minimized window, and every window of a hidden app, isn't visible
    // either: only a window that is none of these has been closed.
    let closed = !p.window.isVisible() && !p.window.isMiniaturized() && !p.app.isHidden();
    if p.open && closed {
        p.open = false;
        p.pending.push_back(GpEvent {
            kind: EV_CLOSE,
            ..Default::default()
        });
        return;
    }
    let Some(view) = p.window.contentView() else {
        return;
    };
    let frame = view.frame();
    let scale = p.window.backingScaleFactor();
    let size = (frame.size.width, frame.size.height);
    if size != p.size || scale != p.scale {
        p.size = size;
        p.scale = scale;
        unsafe {
            p.layer.setContentsScale(scale);
            p.layer
                .setDrawableSize(CGSize::new(size.0 * scale, size.1 * scale));
        }
        p.pending.push_back(GpEvent {
            kind: EV_RESIZE,
            x: scale,
            w: size.0,
            h: size.1,
            ..Default::default()
        });
    }
}

/// Draws the layers (see `compositor`) where they are placed into the window
/// and presents them, over a `background` of 0xAARRGGBB. Waits for a free
/// drawable, which paces a run of frames to the display.
#[unsafe(no_mangle)]
pub extern "C" fn tp_render(background: u32) -> i32 {
    guarded(|| {
        with_platform(|p| {
            let drawable = unsafe { p.layer.nextDrawable() }.ok_or(ERR_METAL)?;
            // Read for every frame: the window may have moved to another screen.
            p.refresh_hz = p
                .window
                .screen()
                .map_or(p.refresh_hz, |s| s.maximumFramesPerSecond() as f64);
            let refresh = p.refresh_hz;
            with_compositor(|c| c.present(&drawable, background, refresh))?;
            p.frames += 1;
            Ok(0)
        })
    })
}

/// The refresh rate of the window's screen, or 0 with no window.
pub(crate) fn refresh_hz() -> f64 {
    PLATFORM.with(|cell| cell.borrow().as_ref().map_or(0.0, |p| p.refresh_hz))
}

/// Wakes the main thread's `tp_next_event` with an EV_WAKE carrying `token`
/// as its code. Safe to call from any thread: a tab worker calls it when a
/// frame is ready.
#[unsafe(no_mangle)]
pub extern "C" fn tp_wake(token: i32) -> i32 {
    guarded(|| {
        dispatch2::DispatchQueue::main().exec_async(move || {
            let Some(mtm) = MainThreadMarker::new() else { return };
            let app = NSApplication::sharedApplication(mtm);
            let event = unsafe {
                NSEvent::otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
                    NSEventType::ApplicationDefined,
                    NSPoint::new(0.0, 0.0),
                    NSEventModifierFlags::empty(),
                    0.0,
                    0,
                    None,
                    0,
                    token as isize,
                    0,
                )
            };
            if let Some(event) = event {
                app.postEvent_atStart(&event, false);
            }
        });
        Ok(0)
    })
}

/// Frames presented since the window opened. For the idle test.
#[unsafe(no_mangle)]
pub extern "C" fn tp_frames() -> i64 {
    if MainThreadMarker::new().is_none() {
        return ERR_NOT_MAIN_THREAD as i64;
    }
    match catch_unwind(|| PLATFORM.with(|cell| cell.borrow().as_ref().map_or(0, |p| p.frames))) {
        Ok(n) => n,
        Err(_) => ERR_PANIC as i64,
    }
}

// Pointer shapes for tp_set_cursor; the Goose side mirrors these numbers.
const CURSOR_ARROW: i32 = 0;
const CURSOR_POINTER: i32 = 1; // a pointing hand, over a link
const CURSOR_TEXT: i32 = 2;
const CURSOR_GRAB: i32 = 3;
const CURSOR_GRABBING: i32 = 4;
const CURSOR_RESIZE_ACROSS: i32 = 5;
const CURSOR_RESIZE_DOWN: i32 = 6;
const CURSOR_CROSSHAIR: i32 = 7;
const CURSOR_NOT_ALLOWED: i32 = 8;

/// Shows pointer shape `kind` (CURSOR_) over the window. Setting the shape
/// already shown does nothing, so Goose may call it on every move.
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_cursor(kind: i32) -> i32 {
    guarded(|| {
        with_platform(|p| {
            if kind == p.cursor {
                return Ok(0);
            }
            let cursor = match kind {
                CURSOR_ARROW => NSCursor::arrowCursor(),
                CURSOR_POINTER => NSCursor::pointingHandCursor(),
                CURSOR_TEXT => NSCursor::IBeamCursor(),
                CURSOR_GRAB => NSCursor::openHandCursor(),
                CURSOR_GRABBING => NSCursor::closedHandCursor(),
                CURSOR_RESIZE_ACROSS => NSCursor::columnResizeCursor(),
                CURSOR_RESIZE_DOWN => NSCursor::rowResizeCursor(),
                CURSOR_CROSSHAIR => NSCursor::crosshairCursor(),
                CURSOR_NOT_ALLOWED => NSCursor::operationNotAllowedCursor(),
                _ => return Err(ERR_ARGUMENT),
            };
            cursor.set();
            p.cursor = kind;
            Ok(0)
        })
    })
}

/// Closes the window and releases everything the platform layer holds.
#[unsafe(no_mangle)]
pub extern "C" fn tp_close() -> i32 {
    guarded(|| {
        MainThreadMarker::new().ok_or(ERR_NOT_MAIN_THREAD)?;
        PLATFORM.with(|cell| {
            if let Some(p) = cell.borrow_mut().take() {
                p.window.close();
            }
        });
        Ok(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_layout_matches_the_goose_struct() {
        assert_eq!(std::mem::size_of::<GpEvent>(), 40);
        assert_eq!(std::mem::align_of::<GpEvent>(), 8);
    }

    #[test]
    fn calls_off_the_main_thread_fail_cleanly() {
        // Test threads are not the main thread: every AppKit entry point must
        // refuse with an error code instead of crashing.
        let title = b"Tusk";
        assert_eq!(
            tp_open(800.0, 600.0, title.as_ptr(), title.len() as i64),
            ERR_NOT_MAIN_THREAD
        );
        let mut e = GpEvent::default();
        assert_eq!(tp_next_event(0, &mut e), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_render(0xFFFF_FFFF), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_frames(), ERR_NOT_MAIN_THREAD as i64);
        assert_eq!(tp_set_cursor(CURSOR_POINTER), ERR_NOT_MAIN_THREAD);
    }

    #[test]
    fn moves_and_scrolls_coalesce_but_nothing_else_does() {
        let mv = |x| GpEvent {
            kind: EV_MOUSE_MOVE,
            x,
            ..Default::default()
        };
        let mut q = VecDeque::new();
        queue(&mut q, mv(1.0));
        queue(&mut q, mv(2.0));
        assert_eq!((q.len(), q[0].x), (1, 2.0));
        queue(
            &mut q,
            GpEvent {
                kind: EV_MOUSE,
                ..Default::default()
            },
        );
        queue(&mut q, mv(3.0));
        assert_eq!(q.len(), 3);
        let scroll = |dy, code, h| GpEvent {
            kind: EV_SCROLL,
            code,
            y: dy,
            h,
            ..Default::default()
        };
        let mut q = VecDeque::new();
        queue(&mut q, scroll(-2.0, 1, 10.0));
        queue(&mut q, scroll(-3.0, 1, 12.0));
        assert_eq!((q.len(), q[0].y, q[0].h), (1, -5.0, 12.0));
        // A wheel's lines don't add to a trackpad's points.
        queue(&mut q, scroll(1.0, 0, 12.0));
        assert_eq!(q.len(), 2);
    }

    #[test]
    fn mouse_events_map_to_pointer_events() {
        assert_eq!(pointer(NSEventType::LeftMouseDown), Some((EV_MOUSE, 0)));
        assert_eq!(pointer(NSEventType::RightMouseUp), Some((EV_MOUSE_UP, 1)));
        assert_eq!(pointer(NSEventType::MouseMoved), Some((EV_MOUSE_MOVE, 0)));
        assert_eq!(
            pointer(NSEventType::LeftMouseDragged),
            Some((EV_MOUSE_MOVE, 1))
        );
        assert_eq!(
            pointer(NSEventType::RightMouseDragged),
            Some((EV_MOUSE_MOVE, 2))
        );
        assert_eq!(pointer(NSEventType::KeyDown), None);
    }

    #[test]
    fn bad_arguments_are_rejected() {
        assert_eq!(tp_next_event(0, std::ptr::null_mut()), ERR_ARGUMENT);
    }
}
