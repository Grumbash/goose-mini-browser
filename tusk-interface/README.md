# Screenshots for the interface PRs

Images the PRs of Tusk's interface stack show. Tusk's are drawn by that
PR's own build with `./app/tusk --screenshot`, from the pages in `pages/`
or, for the design's window, `tests/pages/window.html`. The WebKit ones
come from WKWebView at the same size, for comparison; `pr1-design.png` and
`pr10-design.png` are the design's own window. This branch only holds
images for PR descriptions; it can go once the stack is merged.

From PR 11 on: `pr11-layers.png` and `pr12-input.png` are drawn offscreen by
small scratch programs on the engine (two layers of the article; the hit
bounds of a test page); `pr13-tabs.png`, `pr14-window.png` and
`pr14-loader.png` are Tusk's own window, captured as it ran;
`pr14-panels.png` puts the dev panel's five tabs side by side, each from
`./app/tusk --screenshot --dev-tab NAME`.
