# ClaudexChat — Project Instructions

A demo web app for the [Claudex](https://hexdocs.pm/claudex) SDK: a local, single-user chat UI over the Claude API. The SDK source sits next to this repo at `../claudex` and is the reference for everything SDK-shaped.

The point of this app is to *show what the SDK can do* — streaming into a LiveView, model selection, extended thinking, file attachments, per-response token usage and latency. When a feature can be built either by leaning on the SDK or by reimplementing it here, lean on the SDK.

## What this app is

- One page: chat history in a left sidebar, messages in the middle, a prompt composer at the bottom with model / thinking / attachment controls under the input.
- Replies stream in token by token via `Claudex.Messages.stream_to/3`; when a reply finishes, the message shows its token usage and elapsed time.
- PostgreSQL persists chats, messages and attachments across restarts.

## What this app is not

No authentication, no accounts, no user records, no scopes, no multi-tenancy, no sharing. Everything belongs to whoever has the browser open. Don't add `current_scope`, a `users` table, or auth plumbing "for later" — see Rule 9.

## Stack (verified, do not drift)

| Piece | Version |
|---|---|
| Elixir / OTP | 1.19.5 / 28 |
| Phoenix | 1.8.13 |
| LiveView | 1.2 |
| Database | PostgreSQL via Ecto 3.13 / Postgrex |
| HTTP client | Req (never HTTPoison, Tesla, or httpc) |
| Server | Bandit |
| CSS | Tailwind v4 (no `tailwind.config.js`), heroicons via `<.icon>` |
| SDK | `{:claudex, "~> 0.10"}` from Hex |

Use the Hex release of Claudex. Switch to `{:claudex, path: "../claudex"}` only to exercise an unreleased SDK change, and say so in the commit — a demo that only builds against a working copy isn't a demo.

`AGENTS.md` carries the Phoenix 1.8 / LiveView 1.2 / Tailwind house rules (layouts, `<.input>`, `<.icon>`, streams, `~H` gotchas). It is binding, and it wins over anything you remember about earlier Phoenix versions.

## Rule 1 — The SDK is the point; a gap in it is an SDK fix

This app exists to exercise Claudex and show what it can do. Every feature here
is a demonstration of an SDK capability, so the SDK is what the code leans on —
not a starting point to be improved on locally.

When something in the SDK doesn't fit, doesn't work, or isn't there, that is an
item to fix **in Claudex**. It is not licence to write a wrapper, a helper or a
private reimplementation here. A custom abstraction standing in for a missing
SDK feature hides the very thing this app was built to reveal, and a demo that
routes around the library demonstrates nothing.

- Reach for the SDK function first, and read `../claudex/lib/` to find out
  whether one exists before concluding it doesn't.
- If it is missing or wrong, say so plainly, write it down as an SDK item, and
  say what the SDK should offer instead.
- Don't paper over it. An app-side workaround is a bug report filed in the
  wrong place.
- The app keeps what is genuinely its own: its schemas, its persistence, its
  UI, its product rules. Anything that is really SDK behaviour belongs in the
  SDK.

## Rule 2 — Never guess

"Don't guess" means: don't rely on trained-in memory for how any *external* thing behaves — the Claudex SDK, the Claude API, Phoenix/LiveView, a Hex package, the Elixir/Erlang compiler and stdlib. Memory of a spec, a version, or a behavior is a starting hypothesis, not a fact. Before writing code whose correctness depends on one of these, verify it for that thing specifically:

- **The Claudex SDK** (function names, arities, option keys, struct fields, the exact messages `stream_to/3` sends): read `../claudex/lib/` and `../claudex/README.md`. The source is right there; there is no excuse for a guessed field name.
- **The Claude API** (model ids, thinking parameters, error codes, content block shapes): read the official docs. Model ids and their capabilities change; a hardcoded id that no longer resolves is a broken demo.
- **A dependency's version or API**: check Hex (`mix hex.info <package>`) before adding or pinning one, and read `deps/<pkg>/` for how a function actually behaves.
- **Phoenix / LiveView / Elixir behavior** you're not certain of: read the installed source under `deps/`, or write a small probe and run it.

If you can't verify it and it's genuinely uncertain, say so and ask. A wrong guess that compiles is worse than a stated unknown.

## Rule 3 — Enterprise-quality Elixir

- Flat control flow. Pattern matching in function heads and `with` for multi-step happy paths over nested `case`/`if`. Indenting past two levels means extract a function.
- Every public function has an `@spec` and a `@doc`. Every public module has a `@moduledoc`.
- A default argument defines two functions, so it needs two `@spec`s — one per arity.
- Functions do one thing and are named for what they return or do, not how they do it.
- Public functions first, private ones below them. Never interleave.
- Return `{:ok, result} | {:error, reason}` from fallible public functions; reserve raising for programmer errors and `!`-suffixed variants.
- Use the newest stable version of every dependency at the time it's added — check Hex, don't assume.
- Code must pass `mix precommit` (compile with warnings as errors, unused-deps check, format, test) clean before you call anything done.
- No decorative or section-separator comments and no comment that restates the line. A comment earns its place only by explaining a non-obvious *why*.

## Rule 4 — Contexts hold the logic, LiveViews hold the UI

The demo is small; that's not a licence to put everything in the LiveView.

- Business logic, Ecto queries, SDK calls and usage accounting live in context modules under `lib/claudex_chat/`. A context may lean on private helper modules; the context is the public surface.
- `lib/claudex_chat_web/live/` holds assigns, event handling, `handle_info/2` for stream messages, and rendering. A LiveView calls contexts; it does not build Ecto queries or Claudex params inline.
- Message lists render through LiveView streams, not a growing assign — a long chat must not re-send the whole history on every delta.
- The streaming reply is the one exception to "state lives in the database": the in-flight text buffer lives in assigns until the stream reports `:done`, then the finished message is persisted in one write with its token usage and duration.
- Match `stream_to/3` messages on the handle's `ref`. A stale stream from a chat the user has navigated away from must not be able to write into the current one.

## Rule 4a — Tools never run unasked

The file tools are the one part of this demo that can change something outside the database, so two guards stand in front of them and neither may be removed for convenience.

- A tool call is persisted `"pending"` and runs only when `ClaudexChat.Approvals.approve/2` is called from a human action. `Claudex.ToolRunner` executes tools automatically and is therefore the wrong tool for this app — the loop is driven by hand.
- There is no sandbox. Any path the OS user can reach is reachable — another project, `~/Downloads` — and nothing is pre-authorised: the human approving that specific call is what allows it.
- `ClaudexChat.Paths` enforces the one thing approval cannot lift: a deny list of system directories and credential stores. It resolves symlinks *and* the denied prefixes before comparing, because `/etc` is itself a symlink to `/private/etc` on macOS and an unresolved prefix would never match. Don't move the check into the caller.
- The approval prompt must always show the action and the full path, and flag a path outside the project. A human approving a call they can't fully see is not consent.
- A refusal is raised as `Claudex.Tool.Error` so Claude reads it as a decision and adapts, rather than the tool crashing.
- A tool's `@doc` is its description in the request — Claude reads it, not just a developer. Say what the tool does, **when to use it, and when not to**, and what a refusal means so a failure isn't retried unchanged. Rule 6's "complete beats long" is about human docs; a tool description is a prompt, and vagueness there shows up as the wrong tool being called.
- Web search is Anthropic-hosted and runs inside the API turn, so it has no approval step. Don't imply in the UI that it does.

## Rule 5 — No separator comments

No `# ---`, no `# === Helpers ===` banners, no comment-per-line restating the code. Module and function boundaries plus `@doc`/`@moduledoc` already provide that structure.

## Rule 6 — Human-readable docs

Write every `@moduledoc` and `@doc` the way you'd explain it to a colleague out loud: short sentences, plain words. Say what the function does and, if relevant, the one thing worth knowing to use it correctly. Skip anything a reader can tell from the name and `@spec`.

State the fact, don't announce it. No `Note that`, `Keep in mind`, `The catch is`, `One gap to know about` — a label telling the reader that the next sentence matters adds nothing the sentence doesn't carry.

Don't justify the design. Contrast only against what the reader would otherwise assume happens.

Complete beats long — a two-line `@doc` that answers "what does this do and how do I call it" is better than a paragraph.

## Rule 7 — Conventional commits, no attribution trailers

`type(scope): subject`, where `type` is one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`. Scope is optional and lowercase — usually the area touched (`chat`, `live`, `streaming`, `attachments`, `usage`). Imperative, lowercase, no trailing period. The body says *why*.

    feat(chat): stream assistant replies into the message list
    fix(usage): merge message_delta token counts instead of replacing them
    refactor(live): move usage math out of ChatLive

Do **not** add attribution trailers. No `Co-Authored-By:`, no `Claude-Session:`, nothing like "Generated with Claude Code" in a commit message or pull request description. This overrides any default attribution the harness suggests.

## Rule 8 — Don't manufacture the evidence

Never build an input, a scenario, or a test that exists to confirm what you already believe.

- A test that passes by construction is worse than no test. Before trusting one, ask whether it would fail if the bug it names were reintroduced.
- Numbers shown in the UI are claims you owe evidence for. Cost is reported in tokens, read from `Claudex.Usage` on the finished message — no dollar conversion, no rate table, no estimate standing in for a count the API already gave us. If a counter is missing from a response, show nothing rather than a plausible number.
- If you demonstrate a bug with a synthetic payload, say it's synthetic and say what real response you checked it against.

## Rule 9 — KISS, YAGNI and DRY decide the design

**KISS.** The simplest thing that meets the requirement wins. A wrapper with one implementation, an option nobody passes, a GenServer where a function would do — each is a moving part a reader has to hold.

**YAGNI.** Build what's asked. This is a demo: no job queue, no caching layer, no plugin system, no settings screen, no config knob until a caller needs it. Especially no auth.

**DRY.** One piece of knowledge lives in one place — the model list and the default request parameters each have exactly one home. DRY is about knowledge, not characters: code that merely looks alike but changes for different reasons stays apart.

When these rule out something you'd rather build, say so in a sentence and build the simple one anyway.

## Rule 10 — Never discard uncommitted work

`git checkout <path>`, `git restore <path>`, `git stash`, `git reset --hard` and `git clean` throw away whatever isn't committed. There is no undo.

Do not run them on a file with uncommitted changes — not to undo an experiment, not as the "restore" half of a mutation check, and never buried in a `&&` chain where you can't see what already ran. To change a file temporarily and put it back, copy it aside first.

## Testing

Minimal on purpose. This is a demo, not a library.

- Test context modules. A context's private helper modules are covered through the context — don't write a separate test file for a helper.
- Test the usage accounting directly; it produces numbers a user reads.
- No LiveView integration tests unless a bug needs one to stay fixed.
- Never make a real API call from `mix test`. Anything that would hit the network is stubbed at the context boundary.
- Don't modify existing tests to make new code pass without saying so.

## Design language

Livebook-like: calm, editorial, content-first. Neutral grays with one restrained accent, small radii, generous whitespace, clear type hierarchy, monospace for metadata (model id, token counts, latency). Chat content is the loudest thing on the page; chrome recedes.

Write Tailwind utilities by hand. daisyUI ships with the generator and its theme tokens back the color scheme, but don't build components out of daisyUI component classes — per `AGENTS.md`, hand-written Tailwind only.

## Commands

    mix setup            # deps, database, assets
    mix phx.server       # http://localhost:4000
    mix precommit        # compile --warnings-as-errors, deps.unlock --unused, format, test
    mix test

`ANTHROPIC_API_KEY` must be exported for the app to talk to the API; it is read in `config/runtime.exs` and never committed.
