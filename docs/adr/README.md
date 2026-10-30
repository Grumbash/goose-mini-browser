# Decisions

Each file records one decision that should outlive the commit that made it: the
context, what we chose, and what follows from it. A new decision gets the next
number; a reversed one stays here, marked superseded, with a link to its
replacement.

| # | Decision | Status |
|---|---|---|
| [0001](0001-our-own-engine.md) | Our own engine: Goose for the engine, Rust for what Goose lacks | Proposed |
| [0002](0002-apple-silicon-only.md) | Apple silicon only: arm64 Mac first, then iPhone | Proposed |
| [0003](0003-smooth-first.md) | Smooth first, idle means zero, memory is a budget | Proposed |
| [0004](0004-documents-first.md) | Documents first, then breadth | Proposed |
| [0005](0005-rust-platform-layer.md) | A Rust platform layer instead of Goose's gfx | Proposed |
| [0006](0006-one-renderer.md) | One renderer for pages and the browser's own interface | Proposed |
| [0007](0007-ai-tools-are-users.md) | AI tools are users | Proposed |
| [0008](0008-boards-carry-profiles.md) | Boards carry profiles | Proposed |
| [0009](0009-name-tusk.md) | The browser is called Tusk | Proposed |
| [0010](0010-interface-as-a-document.md) | The interface is a document Goose rebuilds; pages run in tab workers | Proposed |
| [0011](0011-network-through-apples-url-loading.md) | The network goes through Apple's URL loading system | Proposed |

All eleven start as *Proposed*: Vlad made them on 29 and 30 October 2026, and they
become *Accepted* when Gleb merges them.
