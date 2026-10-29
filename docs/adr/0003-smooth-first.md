# 0003. Smooth first, idle means zero, memory is a budget

Date: 29 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

The point of the browser is to be the smoothest and lightest one we have used.
That only means something if it is measured.

## Decision

When smoothness and memory conflict, a dropped frame loses. Every row below is
pass or fail on the M5 Pro (120 Hz display):

| Test | Pass |
|---|---|
| Scroll a long article for 10 s | Every frame under 8.3 ms; zero dropped frames |
| Input to screen (scroll, a key in the address bar) | Visible in the next frame |
| Page loading in the background | Scrolling and typing never wait for network, parsing or layout |
| Window idle, nothing animating | 0% CPU, no frames drawn |
| Memory | Every tab's weight measured and on screen; budgets set from the first measurement and cut 20% per milestone |

The numbers to beat, measured on 29 Oct 2026 (Activity Monitor's memory
figure, shared memory counted once):

| | WebKit shell | Chrome |
|---|---|---|
| One blank tab, whole browser | 58.9–63.2 MB | 389.7–428.5 MB |
| Wikipedia's Focaccia article, page process | 58.9 MB | — |
| GitHub repo page, page process | 182.7–192.7 MB | — |

## Consequences

- Scrolling and animation run on the compositor from what is already on the
  GPU, so a busy page never holds up a frame.
- Nothing polls. A worker that finishes work wakes the main thread; an idle
  window draws nothing.
- Each milestone ends with its pass/fail table green, or with the failure
  written down.
