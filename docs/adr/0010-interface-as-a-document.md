# 0010. The interface is a document Goose rebuilds; pages run in tab workers

Date: 30 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

ADR 0006 has our own engine draw the interface from HTML and CSS. The design we
chose (foundry, round 7: a top bar, page headers, a board view, a hand of board
cards, split view, a dev panel and a bottom panel) is static HTML with no
JavaScript: every state is a CSS class. Our JavaScript engine is M4, Goose has no
heap for a changing number of documents in one thread, and only the main thread
may touch Metal (ADR 0005).

## Decision

- The interface is one HTML document that Goose generates from the browser's
  state (boards, pages, the view, open panels, hover). It is parsed, styled and
  laid out on the main thread, and again only when that state changes. Its CSS,
  icons and fonts live in `app/ui/`.
- Every page runs in its own contained worker (`thread_spawn_contained`), which
  owns the page's document. A worker sends its display list to the main thread as
  one flat message, then wakes it with `tp_wake`.
- The interface marks where pages go (`data-slot`). The compositor draws each
  page as a layer at its slot, with an origin, a clip, a scale and a transform.
  Scrolling a page or dragging a card moves a layer; nothing is laid out again.
- Behaviour lives in Goose, not in scripts. Interface elements carry
  `data-action`; a click finds the topmost interface box under the pointer and
  the nearest action above it, and keys map to the same actions. Agents read the
  interface with `tusk snapshot` and drive it with the same actions (ADR 0007).
- The compositor draws images from texture slots. Decoding images and filling the
  slots is Gleb's (ADR 0001).

## Consequences

- Flex and positioning move from M3 to M2 (ADR 0004): the interface can't wait.
- A page that crashes ends its worker and that tab only.
- Workers need a compiled build (`goose build`); the JIT can't run threads, so
  worker paths are checked through the app's own modes, not the engine checks.
- The DOM stays append-only: each change to the interface builds a new document.
  It is a few hundred elements; the time it takes is measured and shown in the
  dev panel.
- Until images arrive, board cards show their board's colour instead of art.
