# 0004. Documents first, then breadth

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

A complete modern web engine takes funded teams years. Ladybird has a full-time
team and had not shipped its first alpha by its September 2026 newsletter;
Servo passes 66.9% of the Web Platform Tests on its own dashboard (29 Oct 2026).

## Decision

We start where two people can be the best: the document web. Articles, docs,
Wikipedia, MDN, READMEs and blogs. That is where smoothness and weight show most,
and it needs HTML, CSS and text done very well, with little or no JavaScript.

| | Goal | Done when |
|---|---|---|
| M0 | Foundations | Goose pinned and built; the Rust platform layer opens a Metal window, waits for events and draws on demand at 0% idle CPU; CI runs the headless test |
| M1 | One article, perfectly smooth | HTML parser, DOM, a CSS subset, block and inline layout, shaped text, compositor scrolling. A saved copy of the Focaccia article scrolls with zero dropped frames; its weight is measured and shown; `tusk snapshot` reads it as a tree |
| M2 | The live document web | Rust network stack, images, URLs; tabs as contained workers; the interface built in the engine (ADR 0006, ADR 0010), with the flex and positioning it needs |
| M3 | Layout breadth | Grid, tables, floats, scrolling overflow, forms; WPT subsets as regression tests |
| M4 | JavaScript | A measured bake-off of Boa and QuickJS-ng, then DOM bindings, events and `fetch` |
| M5 | iPhone daily driver | The same engine on iOS: touch, the bottom bar, sync with the Mac |

## Consequences

- JavaScript-heavy apps (mail, maps, design tools) come later; until then a page
  we can't render opens in Safari with one key.
- The JavaScript engine is open until the M4 bake-off.
