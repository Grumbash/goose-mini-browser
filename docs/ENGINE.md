# goose engine plan

Draft 1, 29 Oct 2026. Decisions, architecture and milestones for our own browser
engine. Product context lives in [PRODUCT.md](../PRODUCT.md); the visual
directions and the measurements are in [design/](../design/).

## Decisions

- **Private.** A browser for the two of us. Not distributed, so no store rules apply.
- **Our own engine.** Goose for the engine; Rust for every module Goose doesn't have.
- **Apple silicon only.** arm64 Macs first (the M5 Pro is the reference machine), then
  iPhone, installed on our own phones from Xcode. No Intel Macs, no other operating systems.
- **Smooth first, light second.** When the two conflict, a dropped frame loses.

## What "smooth" means

Every row is pass or fail, measured on the M5 Pro MacBook (120 Hz display).

| Test | Pass |
|---|---|
| Scroll a long article for 10 s | Every frame under 8.3 ms; zero dropped frames |
| Input to screen (scroll, a key in the address bar) | Visible in the next frame |
| Page loading in the background | Scrolling and typing never wait for network, parsing or layout |
| Window idle, nothing animating | 0% CPU, no frames drawn |
| Memory | Every tab's weight measured and on screen; budgets set from the first measurement and cut 20% per milestone |

## The numbers to beat

Measured on 29 Oct 2026 (Activity Monitor's memory figure, shared memory counted
once; scripts and raw JSON in `design/measurements/`):

| | WebKit shell | Chrome |
|---|---|---|
| One blank tab, whole browser | 58.9–63.2 MB | 389.7–428.5 MB |
| Wikipedia's Focaccia article, page process | 58.9 MB | — |
| GitHub repo page, page process | 182.7–192.7 MB | — |

## Scope, honestly

A complete modern-web engine takes funded teams years. Ladybird has a full-time
team and had not shipped its first alpha by its September 2026 newsletter; Servo
passes 66.9% of the Web Platform Tests on its own dashboard (29 Oct 2026).

So we start where two people can be the best: the document web. Articles, docs,
Wikipedia, MDN, READMEs, blogs. That is where smoothness and weight show most,
and it needs HTML, CSS and text done very well, with little or no JavaScript.
JavaScript-heavy apps (mail, maps, design tools) come later; until then a page we
can't render opens in Safari with one key.

## Who does what

Goose owns the engine. Rust owns everything Goose lacks, plus the platform layer.
Goose's own graphics layer does run on a Mac (its docs list macOS as untested; it
ran here on 29 Oct), but it redraws every frame with no way to wait for input:
the demo sat at 13.8% CPU and about 116 frames a second while idle, holding
208–235 MB, about 175 MB of it GPU allocations.

| Goose (engine) | Rust (modules) |
|---|---|
| HTML tokenizer and tree builder (the WHATWG algorithm) | Window, input, IME, menus, display link (Metal; `CADisplayLink`) |
| DOM: compact inline nodes with relative links | GPU compositor: layers, tiles, glyph atlas, images, present on demand |
| CSS parser, selector matching, cascade, computed style | Text: Core Text for fonts, fallback and shaping; glyphs rasterized into a shared GPU atlas |
| Layout: block, inline, then flex, grid, tables, positioning | Network: HTTP/1.1 and HTTP/2, TLS (rustls), cookies, cache, gzip/brotli/zstd |
| Paint: a flat display list per frame | URL parsing (WHATWG); images and video through ImageIO and VideoToolbox |
| Tabs, history, the sleep policy, the chrome's logic | JavaScript engine and storage (SQLite) |

**Owners.** Gleb owns images and video: decoding through ImageIO and VideoToolbox
and getting them onto the page. The rest of the Rust side and the Goose engine
start with Vlad (and Claude). The compositor draws an image from a handle the
image module returns (pixels already in shared GPU memory, plus the intrinsic
size); that handle is the whole contract between the two.

Two rules at the boundary, both from bugs in the current demo:

1. Every Rust entry point catches panics and returns an error code. A panic must
   never cross into Goose, where it aborts the whole process.
2. Every tab is a Goose worker started with `thread_spawn_contained`, so a page
   that crashes its worker ends that tab only. No fixed-size buffers for URLs or
   any other web input.

## Apple silicon

One chip family lets the engine drop every cross-platform layer and use what the
hardware gives.

- **One architecture.** arm64 only, on Mac and iPhone. Hot loops (selector
  matching, text measuring, pixel work) use NEON through Goose's `simd` and Rust's
  `std::arch`.
- **Metal, directly.** No cross-platform GPU layer. The compositor drives a
  `CAMetalLayer` from `CADisplayLink`: 120 Hz on ProMotion screens, lower when
  little moves, and no more drawables than smoothness needs.
- **Unified memory.** CPU and GPU share memory, so glyphs and decoded images go
  straight into GPU-visible buffers with no upload copy, and each byte counts once
  in a budget.
- **Performance and efficiency cores.** Input, the compositor and the visible tab
  run at user-interactive priority on the performance cores; network, decoding and
  background tabs run at utility or background priority on the efficiency cores.
  Each Goose worker sets its own priority through a Rust call when it starts.
- **16 KB pages.** Apple silicon uses 16 KB memory pages, so allocation chunks
  are multiples of 16 KB and budgets count whole pages.
- **The OS where it is best.** Rust modules wrap Core Text (fonts, fallback,
  shaping), ImageIO (image formats) and VideoToolbox (hardware video decoding)
  rather than shipping our own copies. Networking stays in Rust (HTTP/2, rustls)
  unless a measurement says the system stack is better.

## Threads

Goose workers share no memory; flat values cross typed queues as one copy.
That shape fits a browser: each tab is its own worker, and ending the worker
frees the whole tab at once.

```
 main thread: Goose program + Rust platform layer        one Goose worker per tab (contained)
 ┌──────────────────────────────────────┐   input        ┌──────────────────────────────────────┐
 │ wait for an event or a display tick   │ ─────────────► │ parse → DOM → style → layout → paint │
 │ compositor: tiles, scroll, animation  │ ◄───────────── │ display list (flat value, one copy)  │
 │ present only when something changed   │  frames        └──────────────────────────────────────┘
 └──────────────────────────────────────┘                           ▲ bytes, glyphs, decoded images
                   ▲                                                  │
                   └──────── Rust IO pool: network · TLS · decode · fonts · storage · JS
```

- Scrolling and animation run on the compositor from rasterized tiles, so a busy
  page never holds up a frame.
- A worker that finishes a display list calls a thread-safe Rust `wake()`, which
  posts an event to the main loop; nothing polls.
- A sleeping tab is a tab whose worker has ended. Its URL, history and scroll
  position stay in the main program, so it comes back with one reload.

## The chrome

The browser's own interface is HTML and CSS rendered by our engine. One renderer
draws everything, the engine gets used every minute of every day, and the chosen
design direction's mockup becomes the first real page the engine has to draw
perfectly.

## Milestones

Each one ends with its pass/fail table green on the M5 Pro.

| | Goal | Done when |
|---|---|---|
| M0 | Foundations | Goose pinned to a commit and built; CI runs the headless screenshot test; a Rust platform crate opens a Metal window, waits for events and draws on demand at 0% idle CPU; the FFI rules above in code; the old demo measured once as a baseline; one Goose + Rust frame drawn on an iPhone (to prove the toolchain early) |
| M1 | One article, perfectly smooth | Spec HTML parser, DOM, a CSS subset (block, inline, fonts, colour, spacing), shaped text, compositor scrolling. A saved copy of the Focaccia article scrolls 10 s with zero dropped frames; its weight is measured and shown |
| M2 | The live document web | Rust network stack, images, URLs; tabs as contained workers; sleep ends the worker; the chosen UI direction built as the chrome |
| M3 | Layout breadth | Flex, grid, tables, positioning, overflow, forms; WPT subsets as regression tests |
| M4 | JavaScript | A measured bake-off of Boa and QuickJS-ng (speed, memory, conformance), then DOM bindings, events and `fetch` |
| M5 | iPhone daily driver | The same engine on iOS: touch, the bottom bar, sync with the Mac |

## Progress

**M0, 29 Oct 2026** (raw results in `design/measurements/`):

- Goose built from `cce94b9` in 114 s on the M5 Pro, exactly as the README says.
- The old demo, idle in a window: 13.8% CPU, about 116 frames a second, 208–235 MB.
- `platform/` (Rust): a native window with a Metal layer and two drawables. The
  main thread sleeps in `gp_next_event`; every entry point catches panics.
- `app/` (Goose, 91 KB): opens the window through the platform layer. Idle in a
  window: 0.0% CPU over 10 s, one frame in total, 27.0 MB.
- A contained Goose worker woke the sleeping main thread through `gp_wake`.

Still open in M0: CI with the headless screenshot test, and one frame on an iPhone.

## Risks

- **Goose is two months old.** Pin a commit (`cce94b9`, 25 Oct 2026, today),
  keep platform code in Rust, and send fixes upstream.
- **The web is enormous.** JavaScript-heavy apps will lag for a long time; the
  open-in-Safari key covers them.
- **The Goose–Rust boundary** costs a call on every DOM access from JavaScript.
  Batch calls and keep hot paths on one side.
- **iPhone:** apps can't JIT, so JavaScript runs interpreted, and iOS kills apps
  that use too much memory. Both favour a small engine.

## Open decisions

- The JavaScript engine, after the M4 bake-off.
- The UI direction (A Station, B Terminal, C Pack) in the design draft.
- The name: Goose is also a programming language and Block's AI agent.
