# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

- Engine (decided 29 Oct 2026, replacing the same day's choice of the system WebKit): our own, written in Goose, with Rust for every module Goose doesn't have. The plan is in `docs/ENGINE.md`.
- Platform layer in Rust (window, input, GPU compositor, display link), because Goose's graphics layer cannot wait for input: the demo idled at 13.8% CPU and 208–235 MB. The Rust layer idles at 0.0% CPU and 27 MB (measured 29 Oct 2026).
- Images and video are Gleb's (decided 29 Oct 2026): ImageIO and VideoToolbox decoding, handed to the compositor as GPU-memory handles.
- The browser's own interface is HTML and CSS rendered by the engine.
- Target (decided 29 Oct 2026): Apple silicon only. arm64 macOS first, then iOS installed from Xcode. No Intel Macs, no other operating systems. The engine uses Metal directly, unified memory, and the performance and efficiency cores (see `docs/ENGINE.md`, "Apple silicon").
- Undecided: the JavaScript engine (Boa or QuickJS-ng, after a measured bake-off).

## Users

Vlad and Gleb, both developers, as their daily browser on Mac and iPhone. The browser is private and will not be distributed (decided 29 Oct 2026). Developer tools appear when a project is opened (dev mode) and stay out of the way otherwise.

## Product Purpose

The smoothest and lightest browser its two users have ever used, with an engine they own end to end. Success is measured, not claimed: zero dropped frames at 120 Hz on the scroll test, 0% CPU when idle, and every tab's memory shown and kept under budget.

## Positioning

A browser engine written in a heap-free language (Goose) for compact pages in memory, with Rust for networking, text, images, GPU and JavaScript. It starts with the document web (articles, docs, Wikipedia, MDN, READMEs) and makes that perfectly smooth before widening.

## Operating Context

- Daily browsing on a 120 Hz MacBook (M5 Pro, macOS 26.5) and an iPhone.
- Developers' work: local servers, docs, code hosting, checking a page on the phone.
- Pages the engine can't render yet open in Safari with one key.

## Capabilities and Constraints

- Measured 29 Oct 2026 on the M5 Pro (footprint, shared memory counted once): a bare WebKit shell used 58.9–63.2 MB with one blank tab; Chrome used 389.7–428.5 MB. Wikipedia's Focaccia article took 58.9 MB in WebKit's page process; a GitHub repo page took 182.7–192.7 MB.
- The current repo is a one-day demo (one commit) with confirmed crash bugs: a hostile chunked response aborts the process, URLs over 200 bytes abort, link resolution is wrong for most real links.
- iOS: no JIT for our app, so JavaScript runs interpreted; iOS ends apps that use too much memory.
- Undecided: product name (working name: goose), sync design, the UI direction.

## Brand Commitments

- Working name only: "goose", from the repository name. Not final.

## Evidence on Hand

- Memory measurements, probe scripts and raw JSON in `design/measurements/`.
- The code review and research in the design draft (`design/goose-browser-draft.html`).
- No users, testimonials or benchmarks of this engine exist yet.

## Product Principles

1. Smooth first: a frame is never late because of network, parsing or layout.
2. Memory is a budget: every part has a number, and the build fails when it goes over.
3. Idle means zero: nothing redraws, polls or runs while nothing changes.
4. One renderer: the engine draws the pages and the browser's own interface.
5. Documents first, then breadth: be the best at the pages we render before rendering more.

## Accessibility & Inclusion

Platform defaults are the floor once the chrome exists: Dynamic Type sizes, VoiceOver, Reduce Motion and increased contrast. No product-specific requirement has been set yet.
