# 0005. A Rust platform layer instead of Goose's gfx

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

Goose's graphics layer does run on a Mac (its docs list macOS as untested; it ran
here on 29 Oct), but it redraws every frame and has no way to wait for input. The
current demo, idle in a window, measured 13.8% CPU and about 116 frames a second,
holding 208–235 MB, about 175 MB of it GPU allocations.

## Decision

The window, input, display link and Metal surface live in a Rust `cdylib`
(`platform/`), driven from Goose's main thread through a C ABI. The main thread
sleeps inside `tp_next_event` until something happens, and a frame is drawn only
when something changed.

Measured on 29 Oct 2026 with the first version of this layer (M0): idle in a
window, 0.0% CPU over 10 s, one frame in total, 27.0 MB. A contained Goose worker
woke the sleeping main thread through `tp_wake`.

## Consequences

- AppKit and Metal objects live on the main thread only; every entry point
  refuses, with an error code, when called from another thread.
- Workers never touch the window: they finish a display list and call
  `tp_wake`, which posts an event to the main loop. Nothing polls.
- The demo in `browser/` keeps Goose's gfx and ui packages until Tusk can do
  what it does; the two programs live side by side in this repository.
