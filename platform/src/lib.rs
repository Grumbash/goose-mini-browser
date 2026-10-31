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
pub mod net;
pub mod tabs;
pub mod text;
pub mod url;

use std::cell::RefCell;
use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};

use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, ClassType, MainThreadMarker, MainThreadOnly, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSCursor, NSEvent,
    NSEventMask, NSEventModifierFlags, NSEventType, NSPasteboard, NSPasteboardTypeString,
    NSTrackingArea, NSTrackingAreaOptions, NSWindow, NSWindowButton, NSWindowStyleMask,
    NSWindowTitleVisibility,
};
use objc2_core_foundation::CGSize;
use objc2_core_graphics::{CGColorSpace, kCGColorSpaceSRGB};
use objc2_foundation::{
    NSDate, NSDefaultRunLoopMode, NSPoint, NSRect, NSSize, NSString, NSUserDefaults,
};
use objc2_metal::MTLPixelFormat;
use objc2_quartz_core::{CAMetalLayer, kCAGravityTopLeft};

pub(crate) use compositor::on_main_thread;
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
const EV_MOUSE: i32 = 4; // a button went down over the content: x, y; code: button (0 left, 1 right, 2 middle, 3 on others); w: modifiers; h: clicks
const EV_SCROLL: i32 = 5; // x, y: deltas; code: 1 for points (trackpads), 0 for lines (wheels); w, h: the pointer
const EV_WAKE: i32 = 6; // code: the token passed to tp_wake
const EV_MOUSE_UP: i32 = 7; // that button went up: as EV_MOUSE; one for each EV_MOUSE, none without
const EV_MOUSE_MOVE: i32 = 8; // the pointer moved: x, y; code: the buttons of EV_MOUSEs still held (bit b for button b); w: modifiers
const EV_MOUSE_LEAVE: i32 = 9; // the pointer left the content
pub(crate) const EV_FRAME: i32 = 10; // code: a tab whose display list waits (tabs.rs)
pub(crate) const EV_REPLY: i32 = 11; // code: a tab whose reply waits

/// One input event, laid out as Goose's `struct Event { kind: i32, code: i32,
/// x: f64, y: f64, w: f64, h: f64 }`.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
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

    /// Copies `src` in, for a type with alignment 1; false, and nothing
    /// copied, unless the slice is exactly as long.
    ///
    /// # Safety
    /// Goose's slice is valid and writable for this call.
    pub unsafe fn copy_from(&self, src: &[T]) -> bool {
        const { assert!(std::mem::align_of::<T>() == 1) };
        if self.count() != Some(src.len()) {
            return false;
        }
        if !src.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(src.as_ptr(), self.data, src.len()) };
        }
        true
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
    pending: VecDeque<(GpEvent, u64)>, // each with its scroll phase (see queue)
    key_texts: VecDeque<String>,       // the text of each EV_KEY in `pending`, in order
    key_text: String,                  // the text of the EV_KEY tp_next_event gave last
    frames: i64,
    tracking: Retained<NSTrackingArea>, // the content's, whose exit is the pointer leaving
    pressed: u32,   // the buttons whose presses Goose was given, bit b for button b
    at: (f64, f64), // where the pointer was last, in the content
    bar: Bar,
}

/// The window's own bar, when Goose draws one (tp_open): its height, where
/// the traffic lights start in it, and where a press drags the window
/// (tp_set_drag_regions). Rects are x, y, w, h in points from the content's
/// top left.
#[derive(Default)]
struct Bar {
    height: f64, // 0: none, and the system's title bar shows
    lights_x: f64,
    full_screen: bool, // the window is, and its title bar is AppKit's
    lights: [f64; 4],  // where the traffic lights are, always AppKit's
    drag: Vec<[f64; 4]>,
    holes: Vec<[f64; 4]>, // controls inside the drag regions
}

/// Who a press goes to, when Goose draws the window's bar.
#[derive(Debug, PartialEq)]
enum Press {
    /// Below the bar: Goose's, and AppKit sees it as usual.
    Goose,
    /// A control in the bar: Goose's alone, so AppKit's title bar under it
    /// doesn't drag the window from there.
    Control,
    /// AppKit's alone: off the content (the edges a window is resized by),
    /// a traffic light, or a drag region, where it moves the window.
    AppKit,
    /// A double click on a drag region: Tusk zooms or minimizes the window.
    TitleClick,
}

fn inside(r: &[f64; 4], x: f64, y: f64) -> bool {
    x >= r[0] && y >= r[1] && x < r[0] + r[2] && y < r[1] + r[3]
}

impl Bar {
    /// Whether (x, y) is in a drag region, on none of its controls.
    fn drags(&self, x: f64, y: f64) -> bool {
        self.height > 0.0
            && self.drag.iter().any(|r| inside(r, x, y))
            && !self.holes.iter().any(|r| inside(r, x, y))
    }

    /// Who a press at (x, y), its `clicks`th, goes to, in a content `size`
    /// big; `left` for the left button.
    fn press(&self, size: (f64, f64), x: f64, y: f64, left: bool, clicks: isize) -> Press {
        if self.height <= 0.0 {
            return Press::Goose;
        }
        if !(x >= 0.0 && y >= 0.0 && x < size.0 && y < size.1) || inside(&self.lights, x, y) {
            return Press::AppKit;
        }
        if y >= self.height {
            return Press::Goose;
        }
        if left && self.drags(x, y) {
            return if clicks == 2 && !self.full_screen {
                Press::TitleClick
            } else {
                Press::AppKit
            };
        }
        Press::Control
    }
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

/// Opens the browser window with a Metal layer, `width` × `height` points.
/// With `bar` above 0 Goose draws the window's bar, that tall: the content
/// takes the whole window, the system's title bar is see-through and its
/// title hidden, and the traffic lights sit in Goose's bar, centred down it
/// and starting `lights_x` across. Call once, on the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_open(
    width: f64,
    height: f64,
    bar: f64,
    lights_x: f64,
    title: *const u8,
    title_len: i64,
) -> i32 {
    guarded(|| {
        let mtm = MainThreadMarker::new().ok_or(ERR_NOT_MAIN_THREAD)?;
        let sizes = width > 0.0
            && height > 0.0
            && (0.0..height).contains(&bar)
            && (0.0..width).contains(&lights_x);
        if !sizes || title_len < 0 || (title.is_null() && title_len > 0) {
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
        let mut style = NSWindowStyleMask::Titled
            | NSWindowStyleMask::Closable
            | NSWindowStyleMask::Miniaturizable
            | NSWindowStyleMask::Resizable;
        if bar > 0.0 {
            style |= NSWindowStyleMask::FullSizeContentView;
        }
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
        if bar > 0.0 {
            // The window is the size asked for, its content all of it.
            window.setTitlebarAppearsTransparent(true);
            window.setTitleVisibility(NSWindowTitleVisibility::Hidden);
            let mut frame = window.frame();
            frame.size = NSSize::new(width, height);
            window.setFrame_display(frame, false);
            // The interface needs room for its bar, its panels and some page.
            window.setContentMinSize(NSSize::new(MIN_WIDTH, MIN_HEIGHT));
        }
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
        let resize = GpEvent {
            kind: EV_RESIZE,
            x: scale,
            w: width,
            h: height,
            ..Default::default()
        };
        pending.push_back((resize, 0));
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
                key_texts: VecDeque::new(),
                key_text: String::new(),
                frames: 0,
                tracking,
                pressed: 0,
                at: (-1.0, -1.0),
                bar: Bar {
                    height: bar,
                    lights_x,
                    ..Default::default()
                },
            })
        });
        with_platform(|p| {
            place_lights(p);
            Ok(0)
        })
    })
}

/// The smallest window with Goose's bar: its bar's controls, the dev panel
/// and room for a page.
const MIN_WIDTH: f64 = 640.0;
const MIN_HEIGHT: f64 = 400.0;

/// Puts the traffic lights in Goose's bar: AppKit's title bar made as tall
/// as it, and the three buttons centred down it from `lights_x`, as far
/// apart as AppKit puts them. AppKit lays its title bar out again now and
/// then (a resize, a new title), so this runs after every event, and moves
/// nothing when they are where they should be.
fn place_lights(p: &mut Platform) {
    // In full screen the title bar is AppKit's, in a strip of its own that
    // slides down when the pointer goes to the top: it is left as it is.
    if p.bar.height <= 0.0 || p.window.styleMask().contains(NSWindowStyleMask::FullScreen) {
        return;
    }
    let kinds = [
        NSWindowButton::CloseButton,
        NSWindowButton::MiniaturizeButton,
        NSWindowButton::ZoomButton,
    ];
    let buttons: Vec<_> = kinds
        .iter()
        .filter_map(|&k| p.window.standardWindowButton(k))
        .collect();
    let (Some(close), Some(next)) = (buttons.first(), buttons.get(1)) else {
        return;
    };
    let (c, n) = (close.frame(), next.frame());
    let y = ((p.bar.height - c.size.height) / 2.0).round();
    let step = n.origin.x - c.origin.x;
    // Where they are in the content, from its top left: AppKit's to press.
    p.bar.lights = [
        p.bar.lights_x,
        y,
        step * (buttons.len() as f64 - 1.0) + c.size.width,
        c.size.height,
    ];
    let Some(container) = (unsafe { close.superview() }).and_then(|v| unsafe { v.superview() })
    else {
        return;
    };
    let placed = c.origin.x == p.bar.lights_x && c.origin.y == y;
    if placed && container.frame().size.height == p.bar.height {
        return;
    }
    let mut frame = container.frame();
    frame.size.height = p.bar.height;
    frame.origin.y = p.window.frame().size.height - p.bar.height;
    container.setFrame(frame);
    for (k, b) in buttons.iter().enumerate() {
        b.setFrameOrigin(NSPoint::new(p.bar.lights_x + step * k as f64, y));
    }
}

/// Where the traffic lights end across Goose's bar, in points: the zoom
/// button's right edge. 0 without a bar, or a window. Their size and gaps
/// are AppKit's, and differ between versions of macOS.
#[unsafe(no_mangle)]
pub extern "C" fn tp_lights_end() -> f64 {
    let mut end = 0.0;
    guarded(|| {
        with_platform(|p| {
            if p.bar.height > 0.0
                && let Some(zoom) = p.window.standardWindowButton(NSWindowButton::ZoomButton)
            {
                let f = zoom.frame();
                end = f.origin.x + f.size.width;
            }
            Ok(0)
        })
    });
    end
}

/// Where a press in Goose's bar drags the window: `drag` and `holes` hold
/// x, y, w, h rects in points from the content's top left, four numbers
/// each; a press in a drag rect and in no hole is AppKit's, which moves the
/// window, zooms it on a double click, or presses a traffic light. Every
/// other press in the bar is Goose's.
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_drag_regions(drag: GSlice<f32>, holes: GSlice<f32>) -> i32 {
    guarded(|| {
        let rects = |g: &GSlice<f32>| -> Result<Vec<[f64; 4]>, i32> {
            let n = g.count().ok_or(ERR_ARGUMENT)?;
            if n % 4 != 0 {
                return Err(ERR_ARGUMENT);
            }
            Ok((0..n / 4)
                .map(|r| std::array::from_fn(|i| unsafe { g.get(r * 4 + i) } as f64))
                .collect())
        };
        let (drag, holes) = (rects(&drag)?, rects(&holes)?);
        with_platform(|p| {
            (p.bar.drag, p.bar.holes) = (drag, holes);
            Ok(0)
        })
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
                if let Some((e, _)) = p.pending.pop_front() {
                    if e.kind == EV_KEY {
                        p.key_text = p.key_texts.pop_front().unwrap_or_default();
                    }
                    unsafe { out.write_unaligned(e) };
                    return Ok(0);
                }
                if !take(p, &until) {
                    unsafe {
                        out.write_unaligned(GpEvent {
                            kind: EV_NONE,
                            ..Default::default()
                        })
                    };
                    return Ok(0);
                }
                // And what is already waiting behind it, so that a burst of
                // moves or scrolls reaches Goose as one.
                let now = NSDate::distantPast();
                for _ in 0..MAX_TAKEN {
                    if !take(p, &now) {
                        break;
                    }
                }
            }
        })
    })
}

/// The most events taken at once beyond the first: a bound, should AppKit
/// keep making them as fast as they are taken.
const MAX_TAKEN: usize = 256;

/// Takes AppKit's next event, waiting until `until` for one; lets AppKit
/// handle it, and queues what Goose gets of it. False when none came.
fn take(p: &mut Platform, until: &NSDate) -> bool {
    // Events Tusk doesn't translate (gestures, key-ups) are consumed here
    // too: release what each one autoreleases before the next, rather than
    // when the whole wait ends.
    autoreleasepool(|_| {
        let next = unsafe {
            p.app.nextEventMatchingMask_untilDate_inMode_dequeue(
                NSEventMask::Any,
                Some(until),
                NSDefaultRunLoopMode,
                true,
            )
        };
        let Some(ev) = next else { return false };
        let kind = ev.r#type();
        let pressing = [
            NSEventType::LeftMouseDown,
            NSEventType::RightMouseDown,
            NSEventType::OtherMouseDown,
        ];
        // The pointer over another of AppKit's windows (the title bar's own
        // strip in full screen, a menu) is AppKit's alone: its position is
        // in that window, not ours.
        let elsewhere = is_pointer(kind) && ev.windowNumber() != p.window.windowNumber();
        // A press: in Goose's bar, AppKit's where it drags the window, else
        // Goose's alone, so that AppKit's title bar under it doesn't start
        // a drag from a control (see Press).
        let mut press = Press::Goose;
        if pressing.contains(&kind) && !elsewhere {
            let at = ev.locationInWindow();
            let (x, y) = (at.x, p.size.1 - at.y);
            let left = kind == NSEventType::LeftMouseDown;
            press = p.bar.press(p.size, x, y, left, ev.clickCount());
        }
        let appkits = press == Press::AppKit || press == Press::TitleClick;
        let in_bar = press == Press::Control;
        let double = press == Press::TitleClick;
        let translated = if appkits || elsewhere {
            None
        } else {
            translate(p, &ev)
        };
        // Our own wake events and key presses stop here: AppKit would beep
        // at keys no responder handles.
        let ours = kind == NSEventType::ApplicationDefined && ev.subtype().0 == OURS;
        if double {
            // With its title bar see-through, AppKit leaves a double click
            // on it to the app: it does what System Settings says.
            let key = NSString::from_str("AppleActionOnDoubleClick");
            let pref = NSUserDefaults::standardUserDefaults().stringForKey(&key);
            match title_click(pref.map(|s| s.to_string()).as_deref()) {
                TitleClick::Zoom => p.window.zoom(None),
                TitleClick::Minimize => p.window.miniaturize(None),
                TitleClick::Nothing => {}
            }
        } else if in_bar {
            // What a click would have done: bring the window and Tusk forward.
            if !p.window.isKeyWindow() {
                p.window.makeKeyAndOrderFront(None);
                p.app.activate();
            }
        } else if !ours && kind != NSEventType::KeyDown {
            p.app.sendEvent(&ev);
        }
        check_window(p);
        place_lights(p);
        if let Some(e) = translated {
            if e.kind == EV_KEY {
                p.key_texts.push_back(key_text(&ev));
            }
            let phase = if kind == NSEventType::ScrollWheel {
                ev.phase().0 as u64 | (ev.momentumPhase().0 as u64) << 32
            } else {
                0
            };
            queue(&mut p.pending, e, phase);
        }
        // A press can start a loop of AppKit's own (a menu, a window drag)
        // that keeps its release: Goose gets the release of each press it
        // was given whose button is up now, unless that is still to come.
        if p.pressed != 0 && pressing.contains(&kind) {
            let held = NSEvent::pressedMouseButtons() as u32;
            for button in 0..32 {
                let bit = 1u32 << button;
                if p.pressed & bit == 0 || held & bit != 0 || release_waiting(p, button) {
                    continue;
                }
                p.pressed &= !bit;
                let up = GpEvent {
                    kind: EV_MOUSE_UP,
                    code: button,
                    x: p.at.0,
                    y: p.at.1,
                    ..Default::default()
                };
                queue(&mut p.pending, up, 0);
            }
        }
        true
    })
}

/// Whether an AppKit event is the pointer's: a press, a release, a move, a
/// scroll, or its entering or leaving.
fn is_pointer(kind: NSEventType) -> bool {
    pointer(kind, 0).is_some()
        || [
            NSEventType::ScrollWheel,
            NSEventType::MouseEntered,
            NSEventType::MouseExited,
        ]
        .contains(&kind)
}

/// What a double click on a window's title bar does: System Settings'
/// "Double-click a window's title bar to", as AppleActionOnDoubleClick
/// holds it. Zoom when it was never set; Fill fills the screen, which zoom
/// comes closest to.
#[derive(Debug, PartialEq)]
enum TitleClick {
    Zoom,
    Minimize,
    Nothing,
}

fn title_click(pref: Option<&str>) -> TitleClick {
    match pref {
        Some("Minimize") => TitleClick::Minimize,
        Some("None") => TitleClick::Nothing,
        _ => TitleClick::Zoom,
    }
}

/// Whether AppKit holds a release of `button` still to be taken.
fn release_waiting(p: &Platform, button: i32) -> bool {
    let mask = match button {
        0 => NSEventMask::LeftMouseUp,
        1 => NSEventMask::RightMouseUp,
        _ => NSEventMask::OtherMouseUp,
    };
    let now = NSDate::distantPast();
    unsafe {
        p.app
            .nextEventMatchingMask_untilDate_inMode_dequeue(
                mask,
                Some(&now),
                NSDefaultRunLoopMode,
                false,
            )
            .is_some()
    }
}

fn translate(p: &mut Platform, ev: &NSEvent) -> Option<GpEvent> {
    let kind = ev.r#type();
    if kind == NSEventType::ApplicationDefined {
        // post_to_main's: the kind in data2, the code in data1.
        if ev.subtype().0 != OURS {
            return None;
        }
        return Some(GpEvent {
            kind: ev.data2() as i32,
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
        // Only the content's own area: AppKit's, round the traffic lights or
        // a tooltip, aren't its edge.
        let ours = ev
            .trackingArea()
            .is_some_and(|a| Retained::as_ptr(&a) == Retained::as_ptr(&p.tracking));
        return ours.then(|| GpEvent {
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
    let (event, button) = pointer(kind, ev.buttonNumber())?;
    p.at = (x, y);
    let e = GpEvent {
        kind: event,
        code: button,
        x,
        y,
        w: modifiers,
        h: if event == EV_MOUSE_MOVE {
            0.0
        } else {
            ev.clickCount() as f64
        },
    };
    route(&mut p.pressed, p.size, e)
}

/// The pointer event an AppKit mouse event is, and its button; a mouse's
/// other buttons are numbered from 2 (`number`).
fn pointer(kind: NSEventType, number: isize) -> Option<(i32, i32)> {
    let other = number.clamp(2, 31) as i32;
    Some(match kind {
        NSEventType::LeftMouseDown => (EV_MOUSE, 0),
        NSEventType::RightMouseDown => (EV_MOUSE, 1),
        NSEventType::OtherMouseDown => (EV_MOUSE, other),
        NSEventType::LeftMouseUp => (EV_MOUSE_UP, 0),
        NSEventType::RightMouseUp => (EV_MOUSE_UP, 1),
        NSEventType::OtherMouseUp => (EV_MOUSE_UP, other),
        NSEventType::MouseMoved
        | NSEventType::LeftMouseDragged
        | NSEventType::RightMouseDragged
        | NSEventType::OtherMouseDragged => (EV_MOUSE_MOVE, 0),
        _ => return None,
    })
}

/// What Goose gets of pointer event `e` (its code the button), in a content
/// `size` big, given the buttons whose presses it was given (`pressed`,
/// kept up to date): a press only over the content, since the title bar and
/// the edges a window is resized by are AppKit's; a release only of a press
/// it was given; a move with the buttons of those still held.
fn route(pressed: &mut u32, size: (f64, f64), e: GpEvent) -> Option<GpEvent> {
    let bit = 1u32 << e.code;
    let code = match e.kind {
        EV_MOUSE => {
            if !(e.x >= 0.0 && e.y >= 0.0 && e.x < size.0 && e.y < size.1) {
                return None;
            }
            *pressed |= bit;
            e.code
        }
        EV_MOUSE_UP => {
            if *pressed & bit == 0 {
                return None;
            }
            *pressed &= !bit;
            e.code
        }
        _ => *pressed as i32,
    };
    Some(GpEvent { code, ..e })
}

/// What a key typed, for a text field: its characters, unless ⌘ or ⌃ makes
/// it a shortcut, without controls and AppKit's function keys (U+F700 to
/// U+F8FF: arrows, Home, F1...).
fn key_text(ev: &NSEvent) -> String {
    let flags = ev.modifierFlags();
    if flags.contains(NSEventModifierFlags::Command)
        || flags.contains(NSEventModifierFlags::Control)
    {
        return String::new();
    }
    let chars = ev.characters().map(|s| s.to_string()).unwrap_or_default();
    typed(&chars)
}

/// `chars` without controls and function keys.
fn typed(chars: &str) -> String {
    chars
        .chars()
        .filter(|&c| c >= ' ' && c != '\u{7f}' && !('\u{f700}'..='\u{f8ff}').contains(&c))
        .collect()
}

/// The text of the key event tp_next_event gave last (empty for none), into
/// `out` when `out` is as long; returns its length either way, so call with
/// an empty `out` to learn it.
#[unsafe(no_mangle)]
pub extern "C" fn tp_key_text(out: GSlice<u8>) -> i32 {
    guarded(|| {
        with_platform(|p| {
            let len = p.key_text.len();
            if out.count() == Some(len) {
                unsafe { out.copy_from(p.key_text.as_bytes()) };
            }
            Ok(len as i32)
        })
    })
}

/// The pasteboard's text, as tp_key_text gives its own: copied into `out`
/// when it is as long, its length returned either way. Main thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_paste(out: GSlice<u8>) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let board = NSPasteboard::generalPasteboard();
        let text = unsafe { board.stringForType(NSPasteboardTypeString) }
            .map(|s| s.to_string())
            .unwrap_or_default();
        if out.count() == Some(text.len()) {
            unsafe { out.copy_from(text.as_bytes()) };
        }
        i32::try_from(text.len()).map_err(|_| ERR_ARGUMENT)
    })
}

/// Puts `text` (UTF-8) on the pasteboard. Main thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_copy(text: GSlice<u8>) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let text = std::str::from_utf8(unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        let board = NSPasteboard::generalPasteboard();
        board.clearContents();
        unsafe { board.setString_forType(&NSString::from_str(text), NSPasteboardTypeString) };
        Ok(0)
    })
}

/// Adds event `e` to the ones waiting for Goose. A move replaces a move just
/// before it, and a scroll is added to a scroll of the same kind and `phase`
/// (a trackpad gesture's, and its momentum's) just before it, so a burst of
/// either costs Goose one hit test or one place.
fn queue(pending: &mut VecDeque<(GpEvent, u64)>, e: GpEvent, phase: u64) {
    if let Some((last, last_phase)) = pending.back_mut() {
        if e.kind == EV_MOUSE_MOVE && last.kind == EV_MOUSE_MOVE {
            *last = e;
            return;
        }
        if e.kind == EV_SCROLL
            && last.kind == EV_SCROLL
            && e.code == last.code
            && phase == *last_phase
        {
            last.x += e.x;
            last.y += e.y;
            last.w = e.w;
            last.h = e.h;
            return;
        }
    }
    pending.push_back((e, phase));
}

/// After AppKit has handled an event: notice a closed window or a new size,
/// and the window going full screen or coming back.
fn check_window(p: &mut Platform) {
    // In full screen AppKit shows the title bar, with the traffic lights, in
    // a strip that slides down with the menu bar: an opaque one, with its
    // title, or it shows nothing there. Back in a window, the bar is Goose's
    // again.
    let full = p.window.styleMask().contains(NSWindowStyleMask::FullScreen);
    if p.bar.height > 0.0 && full != p.bar.full_screen {
        p.bar.full_screen = full;
        p.window.setTitlebarAppearsTransparent(!full);
        p.window.setTitleVisibility(if full {
            NSWindowTitleVisibility::Visible
        } else {
            NSWindowTitleVisibility::Hidden
        });
    }
    // A minimized window, and every window of a hidden app, isn't visible
    // either: only a window that is none of these has been closed.
    let closed = !p.window.isVisible() && !p.window.isMiniaturized() && !p.app.isHidden();
    if p.open && closed {
        p.open = false;
        let close = GpEvent {
            kind: EV_CLOSE,
            ..Default::default()
        };
        p.pending.push_back((close, 0));
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
        let resize = GpEvent {
            kind: EV_RESIZE,
            x: scale,
            w: size.0,
            h: size.1,
            ..Default::default()
        };
        p.pending.push_back((resize, 0));
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
        post_to_main(EV_WAKE, token);
        Ok(0)
    })
}

/// Posts an event of `kind` with `code` to the main thread's queue, from any
/// thread, for tp_next_event to hand to Goose.
/// The subtype Tusk's own application-defined events carry: others, from a
/// framework or another app's helper, are AppKit's to handle.
const OURS: i16 = 0x7475; // "tu"

pub(crate) fn post_to_main(kind: i32, code: i32) {
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
                OURS,
                code as isize,
                kind as isize,
            )
        };
        if let Some(event) = event {
            app.postEvent_atStart(&event, false);
        }
    });
}

/// 1 when the system is in dark mode, 0 when it is light. Any thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_dark_mode() -> i32 {
    guarded(|| {
        let key = NSString::from_str("AppleInterfaceStyle");
        let style = NSUserDefaults::standardUserDefaults().stringForKey(&key);
        Ok(style.is_some_and(|s| s.to_string().eq_ignore_ascii_case("dark")) as i32)
    })
}

/// Sets the window's title to `title`, UTF-8.
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_title(title: GSlice<u8>) -> i32 {
    guarded(|| {
        let title = unsafe { title.as_slice() }.ok_or(ERR_ARGUMENT)?;
        with_platform(|p| {
            p.window
                .setTitle(&NSString::from_str(&String::from_utf8_lossy(title)));
            place_lights(p);
            Ok(0)
        })
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
/// already shown does nothing, so Goose may call it on every move. What is
/// shown is asked of AppKit, which sets the arrow on its own at times (after
/// a resize from the window's edge, on activation).
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_cursor(kind: i32) -> i32 {
    guarded(|| {
        with_platform(|_| {
            let cursor = match kind {
                CURSOR_ARROW => NSCursor::arrowCursor(),
                CURSOR_POINTER => NSCursor::pointingHandCursor(),
                CURSOR_TEXT => NSCursor::IBeamCursor(),
                CURSOR_GRAB => NSCursor::openHandCursor(),
                CURSOR_GRABBING => NSCursor::closedHandCursor(),
                CURSOR_RESIZE_ACROSS => resize_cursor(true),
                CURSOR_RESIZE_DOWN => resize_cursor(false),
                CURSOR_CROSSHAIR => NSCursor::crosshairCursor(),
                CURSOR_NOT_ALLOWED => NSCursor::operationNotAllowedCursor(),
                _ => return Err(ERR_ARGUMENT),
            };
            if Retained::as_ptr(&NSCursor::currentCursor()) != Retained::as_ptr(&cursor) {
                cursor.set();
            }
            Ok(0)
        })
    })
}

/// The cursor for moving a divider across (or down): macOS 15's, or before
/// it the one that one replaced, which an older AppKit has instead.
#[allow(deprecated)]
fn resize_cursor(across: bool) -> Retained<NSCursor> {
    let newer = if across {
        sel!(columnResizeCursor)
    } else {
        sel!(rowResizeCursor)
    };
    match (NSCursor::class().metaclass().responds_to(newer), across) {
        (true, true) => NSCursor::columnResizeCursor(),
        (true, false) => NSCursor::rowResizeCursor(),
        (false, true) => NSCursor::resizeLeftRightCursor(),
        (false, false) => NSCursor::resizeUpDownCursor(),
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
        assert_eq!(
            tp_open(800.0, 600.0, 40.0, 14.0, title.as_ptr(), title.len() as i64),
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
        queue(&mut q, mv(1.0), 0);
        queue(&mut q, mv(2.0), 0);
        assert_eq!((q.len(), q[0].0.x), (1, 2.0));
        let press = GpEvent {
            kind: EV_MOUSE,
            ..Default::default()
        };
        queue(&mut q, press, 0);
        queue(&mut q, mv(3.0), 0);
        assert_eq!(q.len(), 3);
        let scroll = |dx, dy, code, w, h| GpEvent {
            kind: EV_SCROLL,
            code,
            x: dx,
            y: dy,
            w,
            h,
        };
        let mut q = VecDeque::new();
        queue(&mut q, scroll(1.0, -2.0, 1, 4.0, 10.0), 2);
        queue(&mut q, scroll(2.0, -3.0, 1, 5.0, 12.0), 2);
        let s = q[0].0;
        assert_eq!((q.len(), s.x, s.y, s.w, s.h), (1, 3.0, -5.0, 5.0, 12.0));
        // A wheel's lines don't add to a trackpad's points, nor a gesture's
        // end to its middle.
        queue(&mut q, scroll(0.0, 1.0, 0, 5.0, 12.0), 2);
        assert_eq!(q.len(), 2);
        queue(&mut q, scroll(0.0, 1.0, 0, 5.0, 12.0), 4);
        assert_eq!(q.len(), 3);
    }

    #[test]
    fn mouse_events_map_to_pointer_events() {
        assert_eq!(pointer(NSEventType::LeftMouseDown, 0), Some((EV_MOUSE, 0)));
        assert_eq!(
            pointer(NSEventType::RightMouseUp, 1),
            Some((EV_MOUSE_UP, 1))
        );
        assert_eq!(pointer(NSEventType::OtherMouseDown, 3), Some((EV_MOUSE, 3)));
        assert_eq!(
            pointer(NSEventType::OtherMouseUp, 4),
            Some((EV_MOUSE_UP, 4))
        );
        assert_eq!(pointer(NSEventType::LeftMouseUp, 0), Some((EV_MOUSE_UP, 0)));
        for moved in [
            NSEventType::MouseMoved,
            NSEventType::LeftMouseDragged,
            NSEventType::RightMouseDragged,
            NSEventType::OtherMouseDragged,
        ] {
            assert_eq!(pointer(moved, 0), Some((EV_MOUSE_MOVE, 0)));
        }
        assert_eq!(pointer(NSEventType::KeyDown, 0), None);
    }

    #[test]
    fn presses_pair_with_releases_and_moves_carry_the_buttons_held() {
        let size = (100.0, 50.0);
        let at = |kind, code, x, y| GpEvent {
            kind,
            code,
            x,
            y,
            ..Default::default()
        };
        let mut pressed = 0u32;
        // Off the content (the title bar, the edges a window is resized by):
        // no press, and so no release or held button either.
        for (x, y) in [(10.0, -5.0), (-1.0, 10.0), (100.0, 10.0), (10.0, 50.0)] {
            assert_eq!(route(&mut pressed, size, at(EV_MOUSE, 0, x, y)), None);
        }
        assert_eq!(
            route(&mut pressed, size, at(EV_MOUSE_UP, 0, 10.0, 10.0)),
            None
        );
        let moved = route(&mut pressed, size, at(EV_MOUSE_MOVE, 0, 10.0, 10.0));
        assert_eq!(moved.map(|e| e.code), Some(0));
        // Over it: both buttons held, then the right one up.
        let down = route(&mut pressed, size, at(EV_MOUSE, 0, 0.0, 0.0));
        assert_eq!(down.map(|e| (e.kind, e.code)), Some((EV_MOUSE, 0)));
        route(&mut pressed, size, at(EV_MOUSE, 1, 10.0, 10.0)).unwrap();
        let dragged = route(&mut pressed, size, at(EV_MOUSE_MOVE, 0, 300.0, -40.0));
        assert_eq!(dragged.map(|e| (e.code, e.x, e.y)), Some((3, 300.0, -40.0)));
        let up = route(&mut pressed, size, at(EV_MOUSE_UP, 1, 300.0, -40.0));
        assert_eq!(up.map(|e| (e.kind, e.code)), Some((EV_MOUSE_UP, 1)));
        assert_eq!(
            route(&mut pressed, size, at(EV_MOUSE_UP, 1, 0.0, 0.0)),
            None
        );
        assert_eq!(pressed, 1);
    }

    #[test]
    fn typed_text_drops_controls_and_function_keys() {
        assert_eq!(typed("a"), "a");
        assert_eq!(typed("Ж é"), "Ж é");
        assert_eq!(typed("\r\t\u{8}\u{7f}"), "");
        assert_eq!(typed("\u{f702}\u{f703}"), ""); // ← and →
        assert_eq!(typed("😀"), "😀");
    }

    #[test]
    fn bad_arguments_are_rejected() {
        assert_eq!(tp_next_event(0, std::ptr::null_mut()), ERR_ARGUMENT);
    }

    #[test]
    fn a_press_drags_the_window_in_a_drag_region_off_its_controls() {
        let bar = Bar {
            height: 40.0,
            lights_x: 14.0,
            full_screen: false,
            lights: [14.0, 12.0, 60.0, 16.0],
            drag: vec![[0.0, 0.0, 1200.0, 40.0]],
            holes: vec![[72.0, 6.0, 80.0, 28.0], [290.0, 6.0, 620.0, 28.0]],
        };
        assert!(bar.drags(20.0, 20.0)); // the traffic lights
        assert!(bar.drags(200.0, 39.0)); // between controls
        assert!(!bar.drags(100.0, 20.0)); // the plate
        assert!(!bar.drags(500.0, 20.0)); // the address
        assert!(!bar.drags(200.0, 40.0)); // below the bar
        assert!(!bar.drags(1200.0, 20.0)); // past its right edge
        let none = Bar { height: 0.0, ..bar };
        assert!(!none.drags(20.0, 20.0));
    }

    #[test]
    fn a_double_click_on_the_bar_does_what_system_settings_say() {
        assert_eq!(title_click(None), TitleClick::Zoom);
        assert_eq!(title_click(Some("Maximize")), TitleClick::Zoom);
        assert_eq!(title_click(Some("Fill")), TitleClick::Zoom);
        assert_eq!(title_click(Some("Minimize")), TitleClick::Minimize);
        assert_eq!(title_click(Some("None")), TitleClick::Nothing);
    }

    #[test]
    fn the_pointers_events_are_told_from_the_rest() {
        for kind in [
            NSEventType::LeftMouseDown,
            NSEventType::RightMouseUp,
            NSEventType::MouseMoved,
            NSEventType::OtherMouseDragged,
            NSEventType::ScrollWheel,
            NSEventType::MouseExited,
        ] {
            assert!(is_pointer(kind), "{kind:?}");
        }
        for kind in [
            NSEventType::KeyDown,
            NSEventType::ApplicationDefined,
            NSEventType::FlagsChanged,
        ] {
            assert!(!is_pointer(kind), "{kind:?}");
        }
    }

    #[test]
    fn a_press_goes_to_appkit_or_goose_by_where_it_is() {
        let mut bar = Bar {
            height: 40.0,
            lights_x: 14.0,
            full_screen: false,
            lights: [14.0, 12.0, 60.0, 16.0],
            drag: vec![[0.0, 0.0, 1200.0, 40.0]],
            holes: vec![[90.0, 6.0, 80.0, 28.0]],
        };
        let size = (1200.0, 760.0);
        let at = |bar: &Bar, x, y, left, clicks| bar.press(size, x, y, left, clicks);
        // Off the content: the edges a window is resized by.
        for (x, y) in [(10.0, -3.0), (-2.0, 20.0), (1200.0, 20.0), (600.0, 760.0)] {
            assert_eq!(at(&bar, x, y, true, 1), Press::AppKit, "({x}, {y})");
        }
        assert_eq!(at(&bar, 20.0, 20.0, true, 1), Press::AppKit); // a traffic light
        assert_eq!(at(&bar, 20.0, 20.0, false, 1), Press::AppKit);
        assert_eq!(at(&bar, 300.0, 20.0, true, 1), Press::AppKit); // the bar's empty space
        assert_eq!(at(&bar, 300.0, 20.0, true, 2), Press::TitleClick);
        assert_eq!(at(&bar, 300.0, 20.0, false, 1), Press::Control); // a right click there
        assert_eq!(at(&bar, 100.0, 20.0, true, 2), Press::Control); // a control
        assert_eq!(at(&bar, 100.0, 40.0, true, 1), Press::Goose); // below the bar
        bar.full_screen = true;
        assert_eq!(at(&bar, 300.0, 20.0, true, 2), Press::AppKit);
        bar.height = 0.0;
        assert_eq!(at(&bar, 300.0, 20.0, true, 2), Press::Goose);
    }
}
