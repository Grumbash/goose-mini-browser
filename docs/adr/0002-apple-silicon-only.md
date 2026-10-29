# 0002. Apple silicon only: arm64 Mac first, then iPhone

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

We use M-series MacBooks (the M5 Pro is the reference machine) and iPhones. A
cross-platform engine pays for layers it doesn't need: GPU abstraction, a font
stack, threading shims.

## Decision

Tusk targets Apple silicon only: arm64 macOS first, then iOS installed from
Xcode on our own phones. No Intel Macs and no other operating systems.

## Consequences

- **One architecture.** Hot loops (selector matching, text measuring, pixel
  work) use NEON through Goose's `simd` and Rust's `std::arch`.
- **Metal, directly.** No cross-platform GPU layer. The compositor drives a
  `CAMetalLayer`: 120 Hz on ProMotion screens, lower when little moves, and no
  more drawables than smoothness needs.
- **Unified memory.** Glyphs and decoded images go straight into GPU-visible
  buffers with no upload copy, and each byte counts once in a budget.
- **Performance and efficiency cores.** Input, the compositor and the visible
  tab run at user-interactive priority; network, decoding and background tabs
  at utility or background priority. Each Goose worker sets its own priority
  through a Rust call when it starts.
- **16 KB pages.** Allocation chunks are multiples of 16 KB, and budgets count
  whole pages.
- **The OS where it is best.** Rust wraps Core Text for fonts and shaping, and
  ImageIO and VideoToolbox where they win, instead of shipping our own copies.
- **iPhone limits.** Apps can't JIT, so JavaScript runs interpreted, and iOS
  ends apps that use too much memory. Both favour a small engine.
