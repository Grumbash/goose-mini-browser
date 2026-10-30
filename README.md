# goose-mini-browser

A tiny graphical web browser built on [Goose](https://github.com/aardappel/goose),
a brand-new memory-safe systems language with no heap/GC — plus a small Rust
sidecar that gives it the one thing its v1 standard library deliberately
doesn't have: networking.

![screenshot](screenshot.png)

It fetches real pages over `http://` and `https://`, follows redirects,
decodes chunked transfer-encoding, renders basic HTML (headings, paragraphs,
links, line breaks, images, a handful of inline styles) in a resizable
SDL3/Nuklear window, and lets you click between pages — all without
blocking the UI thread while a request or an image decode is in flight.

This is a demo/learning project, not a production browser. See
[Limitations](#limitations) for exactly where it stops.

## Where this is going: Tusk

The demo in `browser/` is the starting point. Beside it we are building **Tusk**:
a browser for the two of us, on an engine of our own written in Goose, with Rust
for the modules Goose doesn't have, for Apple silicon only. Smooth first, idle
means zero, memory is a budget, and AI tools are users too. The decisions behind
it are in [docs/adr/](docs/adr/README.md).

M1 is one article, shown by Tusk's own engine: HTML parsing, the DOM, a CSS
subset and the cascade, block and inline layout in Goose; text shaped by Core
Text and drawn from a glyph atlas by a Metal compositor in Rust.

It builds with the Goose commit that docs/adr/0001 pins, `cce94b9`:

```bash
git init goose && cd goose
git fetch --depth 1 https://github.com/aardappel/goose.git cce94b919d27458856ae2685974049eac78debcf
git checkout --detach FETCH_HEAD
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8
```

```bash
GOOSE_BIN=/path/to/goose ./app/build.sh   # the platform layer (cargo), then the app (goose build)
./app/tusk                                # the saved Focaccia article (tests/pages/)
./app/tusk --scroll-test                  # scrolls it for 10 s and prints what the frames cost
./app/tusk --screenshot out.png           # draws the window offscreen into a PNG, no window
./app/tusk snapshot page.html             # the page as a tree for agents (docs/adr/0007)
goose tests/engine_test.goose             # the engine's checks (after ./app/build.sh)
```

The bar along the bottom shows the page's weight: its size, its nodes, what
parsing, styling, text, layout and paint took, and the process's memory,
weighed again 5 s after the last frame.
Space, Page Up/Down, the arrows, Home and End scroll; ⌘Q quits.

Not yet: images and video, the network (local files only), JavaScript, links
that can be clicked, selection, floats, grid, tables as grids, inline
backgrounds, right-to-left text and colour emoji.

## Why this exists

Goose v1 ships no sockets, no TLS, and no subprocess support by design (see
its `docs/stdlib.md`). Rather than wait for a future version, this project
gives Goose that capability the way its own FFI model intends: a small
Rust `cdylib` exposed through a plain C ABI, dynamically bound from Goose
with `extern "libname" { ... }` — no C toolchain, no cmake, no changes to
the Goose compiler itself.

## Architecture

```
┌─────────────────────────────┐        ┌──────────────────────────┐
│   browser/mini_browser.goose │        │   goosenet (Rust cdylib)  │
│                              │        │                            │
│  HTML scanner/renderer       │  C ABI │  TCP + rustls TLS          │
│  (gfx + ui: SDL3/Nuklear)    │◄──────►│  redirect following        │
│  thread_fn worker + queues   │        │  chunked-encoding decode   │
│  for non-blocking fetches    │        │  one function: fetch(url)  │
└───────────────┬──────────────┘        └──────────────────────────┘
                │ extern "goosenet" { ... }   (dlopen'd at runtime,
                │                              resolved via .build sidecar)
                ▼
        libgoosenet.{dylib,so,dll}
```

- **`goosenet/`** — the Rust side. Two exported entry points:
  `goosenet_fetch(url) -> (status, body)`, which resolves scheme, opens a
  raw TCP socket or a `rustls` TLS connection, follows up to 8 redirects,
  and undoes `Transfer-Encoding: chunked`; and `goosenet_fetch_image(url)`,
  which does the same fetch and then decodes the body as PNG/JPEG/GIF/WebP
  (the `image` crate) and downsamples it to at most 480px on its longest
  side before handing back raw RGBA8 pixels — so decode time, the copy
  across Goose's thread queue, and the GPU texture upload all stay cheap
  regardless of how large the source image actually was. Everything
  crosses the FFI boundary as scalars and raw pointers (see `docs/` link
  below for the exact rules); an owned buffer is handed back as a `u64` +
  length and freed by the Goose side calling `goosenet_free` after copying
  it out.
- **`browser/net.goose`** — a thin Goose wrapper: `extern "goosenet" { ... }`
  binds the functions dynamically (no C compiler involved on the Goose
  side), and `http_get_page`/`fetch_image_rgba` do the FFI call and copy
  the result into Goose-owned memory.
- **`browser/mini_browser.goose`** — the browser itself:
  - a hand-rolled HTML scanner (not a real parser) for `<h1-h3>`, `<p>`,
    `<a href>`, `<br>`, `<img src>`, `<video poster>`,
    `<b>/<strong>/<i>/<em>`, and inline `style="color: ..."`
  - HTML entity decoding (`&amp;`, `&lt;`, numeric `&#NN;`/`&#xHH;`, …)
  - **two** `thread_fn` workers, each consuming jobs off its own typed
    queue (`qget`/`qput`/`qpoll` — Goose has no shared memory between
    threads): one fetches pages, the other fetches+decodes images, so a
    slow network call or a big image never freezes the window or blocks
    the other kind of work. Each image result carries the generation
    counter of the page it was requested for, so a result that arrives
    after the user has already navigated away is dropped instead of
    painting onto the wrong page.
  - a Nuklear UI: address bar, back button, scrollable page view, clickable
    links, and images drawn from a GPU texture uploaded the first frame
    each `<img>`/`<video poster>` is laid out (there is no lazy-load by
    scroll position — every image on the page starts fetching as soon as
    the page does)
- **`browser/mini_browser.build`** — the sidecar that maps `goosenet` to
  `./goosenet` next to the built executable (resolved through
  `resource_dir()`), so the shipped binary needs no `DYLD_LIBRARY_PATH` /
  `LD_LIBRARY_PATH` / `PATH` setup to find its own library.

## Prerequisites

- **Rust** (`cargo`/`rustc`) — any recent stable toolchain.
- **A `goose` compiler**, built from source (there is no package yet):

  ```bash
  git clone --depth 1 https://github.com/aardappel/goose.git
  cd goose
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS=all   # brew install cmake if needed
  cmake --build build -j8
  ```

  `-DGOOSE_BUILTIN_LIBS=all` compiles the `gfx`/`ui` packages (SDL3 +
  Nuklear) straight into the compiler, which this project needs.
- A C compiler on `PATH` (`cc`/`clang`/`gcc`) — `goose build` needs one, and
  so does this project: **threads require AOT compilation**, the in-process
  JIT backend (`goose run`) cannot place thread-local storage.

## Build

```bash
git clone <this-repo>
cd goose-mini-browser
GOOSE_BIN=/path/to/goose/build/goose ./build.sh
```

`build.sh` compiles `goosenet` in release mode, copies the resulting shared
library next to `browser/mini_browser.goose`, and runs `goose build` to
produce a standalone `browser/mini_browser` executable.

## Run

```bash
./browser/mini_browser "https://example.com/"
./browser/mini_browser browser/page1.html     # a bundled local demo page
```

- Type a URL or path in the address bar and press **Go**, or click a link.
- **←** goes back through history.
- **Esc** or closing the window quits.
- `-- --frames N` renders exactly `N` frames and exits (used for headless
  screenshot testing — see `GOOSE_GFX_HEADLESS=1` below).

## Headless testing

```bash
GOOSE_GFX_HEADLESS=1 ./browser/mini_browser "https://example.com/" --frames 300
```

opens no real window, runs the given number of frames, and saves
`mini_browser.png` on exit — useful for CI or for verifying a change
without eyeballing a live window.

## Limitations

This is a learning project built to see how far Goose + a minimal Rust FFI
shim can go, not a spec-compliant browser. Known, intentional gaps:

- **No CSS layout.** `style="color: ..."` and `<b>/<strong>/<i>/<em>` are
  recognized and change text color (there's no second font loaded, so true
  bold/italic glyphs aren't rendered), applied per block, not per inline
  span. No box model, no flexbox/grid, no positioning.
- **No JavaScript.** Pages that render their content client-side (most
  modern web apps, social feeds, SPAs) show nothing meaningful.
- **No cookies/sessions.** Every request is anonymous; anything requiring
  login won't show authenticated content.
- **No real video.** `<video poster="...">` shows the poster frame as a
  still image; without a poster it's a `[video, no poster]` text line.
  There is no decoder, no playback, no audio.
- **Images are capped at 480px** on their longest side (deliberately, for
  decode/memory/GPU-upload cost) and fetched eagerly, all at once, with no
  lazy-loading by scroll position and no local-file image support (`goosenet`
  only speaks HTTP(S); a local page's `<img src="./cat.png">` will show
  "failed to load").
- **gzip/deflate aren't decoded** — pages that insist on compression
  despite no `Accept-Encoding` header may render as binary noise.
- **The HTML scanner is not a real parser**: no error recovery beyond
  "ignore anything it doesn't recognize," no `<table>`/`<ul>`/`<ol>`
  support, no handling of malformed markup beyond what falls out naturally.
- **URL resolution is "same directory" only** — no `..`, no full RFC 3986
  resolution.

## License

MIT — see [LICENSE](LICENSE). The fonts in `app/fonts` (Barlow Condensed, JetBrains Mono)
are under the SIL Open Font License 1.1, in the `OFL-*.txt` files beside them.

## Acknowledgments

Built on [Goose](https://github.com/aardappel/goose) by Wouter van
Oortmerssen — a systems language with no heap allocator, garbage collector,
or lifetime annotations, whose compiler was largely written by an AI
working from his architecture and design. Networking is handled by
[rustls](https://github.com/rustls/rustls) and
[webpki-roots](https://github.com/rustls/webpki-roots).
