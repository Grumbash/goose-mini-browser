# 0001. Our own engine: Goose for the engine, Rust for what Goose lacks

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

The browser is for the two of us and will not be distributed. The question was
whether to build on the system's WebKit or to own the engine. WebKit would give
the whole web on day one; it would also give us WebKit's weight, its threading
and its schedule, and nothing to learn from.

## Decision

We write our own engine. Goose owns the engine itself: the HTML tokenizer and tree
builder, the DOM, CSS parsing, selector matching and the cascade, layout and
paint. Rust owns every module Goose doesn't have: the platform layer (window,
input, the display link), the GPU compositor, text (fonts, fallback, shaping),
networking, image and video decoding, storage and JavaScript.

| Goose (engine) | Rust (modules) |
|---|---|
| HTML tokenizer and tree builder (the WHATWG algorithm) | Window, input, IME, menus, display link |
| DOM: compact nodes in one array, linked by index | GPU compositor: layers, tiles, glyph atlas, present on demand |
| CSS parser, selector matching, cascade, computed style | Text: Core Text for fonts, fallback and shaping |
| Layout: block and inline, then flex, grid, tables, positioning | Network: HTTP/1.1, /2 and /3, TLS, cookies, cache, through Apple's URL loading system (ADR 0011) |
| Paint: a flat display list | Images and video; the JavaScript engine; storage |
| Tabs, history, the sleep policy, the interface's logic | |

## Consequences

- Every Rust entry point catches panics and returns an error code. A panic must
  never cross into Goose, where it aborts the whole process.
- Every tab is a Goose worker started with `thread_spawn_contained`, so a page
  that crashes its worker ends that tab only. No fixed-size buffers for URLs or
  any other web input.
- The Goose–Rust boundary costs a call. Batch calls and keep hot paths on one
  side; the display list crosses as one flat array.
- Gleb owns images and video: decoding, and getting the pixels to the
  compositor. The rest of the Rust side and the Goose engine start with Vlad.
- Goose is two months old. We pin a commit (`cce94b9`, 25 Oct 2026), keep
  platform code in Rust, and send fixes upstream.
- Pages the engine can't render yet open in Safari with one key.
