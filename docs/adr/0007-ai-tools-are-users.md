# 0007. AI tools are users

Date: 30 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

It is the AI era. Claude Code, Claude Desktop and other agents will use the
browser as much as we do. An engine of our own can give them what it already
knows about a page, instead of screenshots and guesswork through a protocol
built for someone else's engine.

## Decision

The browser is built for AI tools as much as for us, from M1 on.

- **One API, two clients.** Everything the browser does is a call: open a URL,
  list boards and pages, read a page, click, type, scroll, take a screenshot,
  read the console and the network log, run JavaScript, wait for an event. The
  `tusk` command line and a built-in MCP server both speak it. Our own dev tools
  use the same calls, so the API can't fall behind them.
- **The page as a tree, not a picture.** A page reads as a compact tree: role,
  name, state, position and a stable reference for each element, plus the main
  text. References are engine node ids, so they survive reflow and restyling.
  VoiceOver reads the same tree, so accessibility and agents share one tree.
- **Events, not polling.** Agents wait for load, network idle and "frame
  settled". Nothing sleeps and retries.
- **Headless or watched.** The same engine runs with or without a window. An
  agent works on a board of its own, on a sandbox profile with no logins and
  nothing kept: we can watch it, take over or close it.
- **Pages are untrusted.** Page text reaches an agent as data, never as
  instructions, and the API marks what came from the page. Agents never see saved
  passwords or payment details; submitting, buying or sending waits for our OK.
- **Measured like the rest.** Snapshot time and size per page join frame times
  and memory in the numbers we track.

## Consequences

- M1 ships the first piece: `tusk snapshot <file>` prints a page as that tree.
- Open: whether to also speak WebDriver BiDi, so Playwright and other test tools
  can drive the browser.
