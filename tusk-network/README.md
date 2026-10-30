# Screenshots for the network PRs

Images the PRs of Tusk's network stack (M2) show, and the interface's
[15/15]. Tusk's are drawn by that PR's own build with
`./app/tusk --screenshot`: the window, or `--bare` for the page alone. The
live pages (en.wikipedia.org/wiki/Focaccia, MDN's `display` page) were
loaded on 31 Oct 2026; the saved article is `tests/pages/focaccia.html`.
WebKit's half comes from WKWebView at the same size, for comparison.

- `pr0-window.png`, `pr0-readout.png`: [15/15] of the interface, the Oil
  tab and the readout (twice its size).
- `pr5-documents.png`: [5/16], the live article before its sheets.
- `pr7-media.png`, `pr9-media.png`: [7/16] and [9/16], the live article
  at 1200 × 800, Tusk left and WebKit right.
- `pr14-network.png`: [14/16], the Network tab on MDN.
- `pr15-images.png`: [15/16], the saved article's infobox before and after.

This branch only holds images for PR descriptions; it can go once the
stacks are merged.
