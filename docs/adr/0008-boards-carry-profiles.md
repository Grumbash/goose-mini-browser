# 0008. Boards carry profiles

Date: 30 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

We keep separate identities: personal accounts, work accounts, and, for agents,
none at all. Browsers make you switch whole profiles, each a separate window and
a separate set of tabs.

## Decision

Pages live on boards (workspaces of pages we arrange and resize), and every board
belongs to a profile: its own cookies, logins, cache and site data, one store per
profile. Boards can share a profile. Switching boards switches profiles, so the
browser has no profile switcher.

## Consequences

- Storage is keyed by profile from the first line of cookie and cache code (M2).
- An agent's board uses a sandbox profile: no logins, nothing kept (ADR 0007).
