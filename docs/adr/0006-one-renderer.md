# 0006. One renderer for pages and the browser's own interface

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

Browsers usually draw their interface with a native toolkit and pages with the
engine: two renderers, two sets of bugs, and an engine that is only exercised by
the pages we visit.

## Decision

Tusk's interface (the top bar, the boards, the bottom panel, the dev panel) is
HTML and CSS drawn by our own engine. The engine is then used every minute of
every day, and the chosen design becomes the first real page it must draw
perfectly.

## Consequences

- The interface waits for the layout it needs: flex and positioning, moved into
  M2 for it (ADR 0010).
  M1 ships the engine with a page and a minimal overlay, not the interface.
- The design work lives outside this repository; it comes in as the HTML and CSS
  of the interface when the engine can draw it.
