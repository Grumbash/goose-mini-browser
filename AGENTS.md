# AGENTS.md

How coding agents work with me in this repository. This is harness-neutral: Claude Code, Codex and Cursor all read it. `CLAUDE.md` holds only a pointer here.

## Who I am and why the workflow looks like this

I want to understand my own code, not just close tasks. So the agent explains before it codes, I write the core logic myself, and every task ends with a short retro. If a rule here gets in the way of a one-line fix, skip the steps that have nothing to say about it.

## Project at a glance

- What it is: a tiny GUI web browser written in [Goose](https://github.com/aardappel/goose) (a young, heap-free, GC-free systems language), with the HTTP(S) networking Goose v1 doesn't ship bolted on via a small Rust FFI shim.
- Stack: Goose compiled to C (the `browser/` program — HTML scanning, an SDL3/Nuklear UI via the `gfx`/`ui` packages, a `thread_fn` worker for non-blocking fetches) + Rust (`goosenet/`, a `cdylib` using `rustls`/`webpki-roots`, exposed through a plain C ABI and bound with `extern "goosenet" { ... }`).
- Glossary: none yet — this is a small two-crate project; a `CONTEXT.md` is worth starting once the vocabulary (job queues, the HTML scanner's block/kind model, the FFI boundary's ownership rules) needs to stop living only in comments.
- Decisions: no `docs/adr/` yet. Start one the first time a non-obvious choice (e.g. why `thread_fn` + typed queues instead of callbacks, why hand-rolled HTML scanning instead of a real parser) needs to survive past the commit that made it.

## Commands

- Install/build: `./build.sh` (compiles `goosenet` in release mode, copies the shared library next to the Goose sources, runs `goose build`). Needs `cargo` and a `goose` compiler on `PATH` or at `$GOOSE_BIN` — see `README.md#prerequisites`.
- Narrow check (Goose, fast iteration): `goose check browser/mini_browser.goose` — typechecks only, including lifetime/root errors, no C compile.
- Narrow check (Rust): `cd goosenet && cargo check`
- Full build + smoke test: `./build.sh && GOOSE_GFX_HEADLESS=1 ./browser/mini_browser "<url>" --frames 300` then inspect the saved `mini_browser.png`. There is no automated test suite yet (see below).
- Format: `cd goosenet && cargo fmt` (Rust); `goose fmt browser/*.goose` (Goose, `docs/command_line.md` §9).
- Lint: `cd goosenet && cargo clippy`

No `cargo test` / Goose test harness exists yet in either crate. Until one does, "tests" means: `goose check` passing, a clean `cargo build --release`, and a headless screenshot that actually shows the expected content (see `goose-lang` skill's note on `GOOSE_GFX_HEADLESS=1` — a program exiting 0 is not proof anything rendered).

## The task loop

1. **Frame it before any detail.** Every task, and every explanation of code, opens in plain words, in this order:
   1. **JTBD**: "When <situation>, <who> wants <motivation>, so that <outcome>", plus one concrete example.
   2. **Pre-mortem**: if this stays as it is, who gets hurt, how often and how badly.
   3. **Given / When / Then** for the example. This becomes the red test in step 4.
   4. **Socratic question**: ask me to predict what happens and where, then correct me.

   Then ask me to retell it in my own words (teach-back) and point out the gaps. Don't ask "understood?". Code, files and fields come only after this. List what is still unknown.
2. **One task, one branch, one session.** Branch name: `<prefix>/<short-slug>` (`feat/`, `fix/`, `refactor/`, `docs/`, `ci/`).
3. **Zone walkthrough.** How the area works (the HTML scanner's state machine, the FFI boundary's ownership rules, the gfx/ui render loop, the `goosenet` fetch/redirect/dechunk pipeline — whichever is touched), and where the relevant code/tests live. End with 3–5 bullets.
4. **Red signal before any fix.** Reproduce the failure (a failing `goose check`, a crash, a wrong screenshot, a Rust panic) before changing anything, and show me it fails.
5. **Options, then a choice.** Give 2–3 options with trade-offs and a recommendation. I pick. The reasoning goes into the PR or commit description.
6. **Who writes what.**
   - **I write the core logic.** The agent gives hints, answers questions and reviews. It doesn't write the core unless I ask.
   - **The agent writes the periphery**: build script changes, docs, formatting, renames, small mechanical edits, headless-screenshot verification.
   - A task can hand the core to an independent subagent instead. Then I review its work.
7. **Verify.** Narrow check, then the full build + headless screenshot, then an independent review by a separate subagent. The writer is never the reviewer.
8. **Ship.** Open a PR (or commit to `main` for trivial changes, e.g. a typo or a comment) and fix review comments.
9. **Retro, three lines:** what I learned, what surprised me, and what to change in this file. Changes to the workflow are made here.

## Principles

- **YAGNI.** Do the simplest thing that works. No abstractions "for later" — this project already has a documented habit of choosing the cheap, honest stand-in (block-level color instead of a CSS cascade, a hand-rolled scanner instead of a real HTML parser) over building infrastructure nothing asked for yet.
- **Ask, don't guess**, when a decision is mine: product behaviour (what the browser should do with a page it can't render), naming that will stick, or anything hard to undo (API shape across the Goose/Rust FFI boundary).
- **Before an autonomous run, commit a checkpoint.** If a run goes wrong, restart it rather than patching it.
- **Report honestly.** If `goose check` or `cargo build` fails, show the output. If a headless screenshot wasn't actually inspected, say so — don't infer "it rendered" from exit code 0.

## Docs

- Design notes and specs: none yet beyond `README.md`'s architecture section and this file. Don't create parallel spec folders — extend `README.md` or start `docs/adr/` (see above) instead.
- Update `README.md`'s Limitations section the moment a listed gap closes (gzip support landing, images, etc.) — it is the single source of truth for "what this does and doesn't do yet," not a changelog.

## Git

- Commit messages describe the change in plain words.
- **No AI co-author or "Generated with…" lines** in commits or PRs. The history lists only people.
- Don't push, force-push or rewrite history without my explicit OK.
- **Keep PRs minimal.** One concern per PR — a PR that touches `goosenet/` networking logic and `browser/` rendering logic at once should usually be two. Small, reviewable diffs over one PR that "also fixes a few other things while I was in there."
- **Use stacked PRs (`gh pr create --base <parent-branch>`) when a change depends on another one that isn't merged yet**, instead of waiting for the parent to land or folding both changes into one PR. See the `github` skill's `references/pr-workflow.md` §8 for the exact commands (numbering titles `[1/2]`/`[2/2]`, retargeting children when landing). This is encouraged, not mandatory — a single small PR with no dependency doesn't need a stack.

## Communication

- I may write in Russian. Code, commits and docs are in English.
- Short answers. A recommendation, not an overview of every option.
