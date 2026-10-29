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

use std::cell::RefCell;
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSEvent, NSEventMask,
    NSEventModifierFlags, NSEventType, NSWindow, NSWindowStyleMask,
};
use objc2_core_foundation::CGSize;
use objc2_foundation::{NSDate, NSDefaultRunLoopMode, NSPoint, NSRect, NSSize, NSString};
use objc2_metal::{
    MTLClearColor, MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue,
    MTLCreateSystemDefaultDevice, MTLDevice, MTLLoadAction, MTLPixelFormat,
    MTLRenderPassDescriptor, MTLStoreAction,
};
use objc2_quartz_core::{CAMetalDrawable, CAMetalLayer};

// Error codes returned to Goose. Zero or positive means success.
const ERR_NOT_MAIN_THREAD: i32 = -1;
const ERR_NOT_OPEN: i32 = -2;
const ERR_METAL: i32 = -3;
const ERR_ARGUMENT: i32 = -4;
const ERR_PANIC: i32 = -100;

// Event kinds; the Goose side mirrors these numbers.
const EV_NONE: i32 = 0; // the wait timed out
const EV_CLOSE: i32 = 1;
const EV_RESIZE: i32 = 2; // w, h: content size in points; x: backing scale
const EV_KEY: i32 = 3; // code: macOS virtual key code
const EV_MOUSE: i32 = 4; // x, y: points from the top-left; code: button
const EV_SCROLL: i32 = 5; // x, y: scroll deltas in points
const EV_WAKE: i32 = 6; // code: the token passed to tp_wake

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

struct Platform {
    app: Retained<NSApplication>,
    window: Retained<NSWindow>,
    layer: Retained<CAMetalLayer>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    size: (f64, f64),
    scale: f64,
    open: bool,
    pending: VecDeque<GpEvent>,
    frames: i64,
}

thread_local! {
    // AppKit objects live on the main thread only, so the state does too.
    static PLATFORM: RefCell<Option<Platform>> = const { RefCell::new(None) };
}

/// Runs `f`, turning a panic into ERR_PANIC so it never unwinds into Goose.
fn guarded(f: impl FnOnce() -> Result<i32, i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
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

        let device = MTLCreateSystemDefaultDevice().ok_or(ERR_METAL)?;
        let queue = device.newCommandQueue().ok_or(ERR_METAL)?;
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
        }
        let view = window.contentView().ok_or(ERR_ARGUMENT)?;
        // Layer-hosting view: the layer is set before wantsLayer.
        view.setLayer(Some(&**layer));
        view.setWantsLayer(true);

        window.makeKeyAndOrderFront(None);
        app.activate();

        PLATFORM.with(|cell| {
            *cell.borrow_mut() = Some(Platform {
                app,
                window,
                layer,
                queue,
                size: (width, height),
                scale,
                open: true,
                pending: VecDeque::new(),
                frames: 0,
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
                    unsafe { *out = e };
                    return Ok(0);
                }
                let next = unsafe {
                    p.app.nextEventMatchingMask_untilDate_inMode_dequeue(
                        NSEventMask::Any,
                        Some(&until),
                        NSDefaultRunLoopMode,
                        true,
                    )
                };
                let Some(ev) = next else {
                    unsafe { *out = GpEvent { kind: EV_NONE, ..Default::default() } };
                    return Ok(0);
                };
                let translated = translate(p, &ev);
                // Our own wake events and key presses stop here: AppKit would
                // beep at keys no responder handles.
                let kind = ev.r#type();
                if kind != NSEventType::ApplicationDefined && kind != NSEventType::KeyDown {
                    p.app.sendEvent(&ev);
                }
                check_window(p);
                if let Some(e) = translated {
                    p.pending.push_back(e);
                }
            }
        })
    })
}

fn translate(p: &Platform, ev: &NSEvent) -> Option<GpEvent> {
    let kind = ev.r#type();
    if kind == NSEventType::ApplicationDefined {
        return Some(GpEvent { kind: EV_WAKE, code: ev.data1() as i32, ..Default::default() });
    }
    if kind == NSEventType::KeyDown {
        return Some(GpEvent { kind: EV_KEY, code: ev.keyCode() as i32, ..Default::default() });
    }
    if kind == NSEventType::LeftMouseDown || kind == NSEventType::RightMouseDown {
        let at = ev.locationInWindow();
        let button = if kind == NSEventType::LeftMouseDown { 0 } else { 1 };
        return Some(GpEvent { kind: EV_MOUSE, code: button, x: at.x, y: p.size.1 - at.y, ..Default::default() });
    }
    if kind == NSEventType::ScrollWheel {
        return Some(GpEvent { kind: EV_SCROLL, x: ev.scrollingDeltaX(), y: ev.scrollingDeltaY(), ..Default::default() });
    }
    None
}

/// After AppKit has handled an event: notice a closed window or a new size.
fn check_window(p: &mut Platform) {
    if p.open && !p.window.isVisible() {
        p.open = false;
        p.pending.push_back(GpEvent { kind: EV_CLOSE, ..Default::default() });
        return;
    }
    let Some(view) = p.window.contentView() else { return };
    let frame = view.frame();
    let scale = p.window.backingScaleFactor();
    let size = (frame.size.width, frame.size.height);
    if size != p.size || scale != p.scale {
        p.size = size;
        p.scale = scale;
        unsafe {
            p.layer.setContentsScale(scale);
            p.layer.setDrawableSize(CGSize::new(size.0 * scale, size.1 * scale));
        }
        p.pending.push_back(GpEvent { kind: EV_RESIZE, x: scale, w: size.0, h: size.1, ..Default::default() });
    }
}

/// Draws one frame cleared to the given colour and presents it. M0 only
/// proves the path; the compositor replaces this in M1.
#[unsafe(no_mangle)]
pub extern "C" fn tp_present(r: f64, g: f64, b: f64) -> i32 {
    guarded(|| {
        with_platform(|p| {
            let drawable = unsafe { p.layer.nextDrawable() }.ok_or(ERR_METAL)?;
            let texture = unsafe { drawable.texture() };
            let pass = unsafe { MTLRenderPassDescriptor::renderPassDescriptor() };
            unsafe {
                let color = pass.colorAttachments().objectAtIndexedSubscript(0);
                color.setTexture(Some(&*texture));
                color.setLoadAction(MTLLoadAction::Clear);
                color.setClearColor(MTLClearColor { red: r, green: g, blue: b, alpha: 1.0 });
                color.setStoreAction(MTLStoreAction::Store);
            }
            let commands = p.queue.commandBuffer().ok_or(ERR_METAL)?;
            let encoder = unsafe { commands.renderCommandEncoderWithDescriptor(&pass) }.ok_or(ERR_METAL)?;
            encoder.endEncoding();
            commands.presentDrawable(ProtocolObject::from_ref(&*drawable));
            commands.commit();
            p.frames += 1;
            Ok(0)
        })
    })
}

/// Wakes the main thread's `tp_next_event` with an EV_WAKE carrying `token`.
/// Safe to call from any thread: a tab worker calls it when a frame is ready.
#[unsafe(no_mangle)]
pub extern "C" fn tp_wake(token: i64) -> i32 {
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
    match catch_unwind(|| PLATFORM.with(|cell| cell.borrow().as_ref().map_or(0, |p| p.frames))) {
        Ok(n) => n,
        Err(_) => ERR_PANIC as i64,
    }
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
        assert_eq!(tp_open(800.0, 600.0, title.as_ptr(), title.len() as i64), ERR_NOT_MAIN_THREAD);
        let mut e = GpEvent::default();
        assert_eq!(tp_next_event(0, &mut e), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_present(0.0, 0.0, 0.0), ERR_NOT_MAIN_THREAD);
    }

    #[test]
    fn bad_arguments_are_rejected() {
        assert_eq!(tp_next_event(0, std::ptr::null_mut()), ERR_ARGUMENT);
    }
}
