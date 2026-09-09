# ClaudexChat

A local chat UI for the Claude API, built to show what the
[Claudex](https://hexdocs.pm/claudex) Elixir SDK can do: replies streamed into
a LiveView, model and thinking selection driven by the API's own capability
data, file attachments, and per-reply token usage and latency.

No accounts, no authentication, no sharing — everything belongs to whoever has
the browser open.

## Requirements

- Elixir 1.19 / OTP 28
- PostgreSQL on `localhost:5432`, reachable as `postgres`/`postgres`
  (change the host and port in `config/dev.exs` and `config/test.exs`)
- An Anthropic API key

## Running it

```sh
mix setup
mix phx.server
```

Then open <http://localhost:4000>.

### The API key

Either put it in a config file — `config/dev.local.exs`, which is git-ignored:

```elixir
import Config

config :claudex, api_key: "sk-ant-..."
```

or export it:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

The environment variable wins when both are set. With neither the app still
starts, but the composer is disabled and says why, and the model picker falls
back to a built-in list instead of asking the Models API.

## What it does

- **Chats** are listed most-recently-active first and named after their first
  message. They live in PostgreSQL, so they survive a restart.
- **Replies stream in** through `Claudex.Messages.stream_to/3`, which runs the
  request in its own process and posts events to the LiveView.
- **Thinking** is offered per model, in the form that model accepts: `adaptive`
  on current models, a token budget on Haiku 4.5 and older. The reasoning is
  shown in a collapsible panel, and the block is replayed on later turns so the
  API accepts the history.
- **Attachments** go to the Claude Files API; a message stores the `file_id`,
  not the bytes.
- **Tools run on this machine, with your approval.** Claude can ask to list a
  directory or read, write and edit a file. Each request appears in the
  conversation showing the action and the full path, and does nothing until
  you press Approve or Deny. Denying tells Claude it was refused, and it
  carries on from there.
- **Nothing is pre-authorised, and nothing is sandboxed.** Another project or
  `~/Downloads` is reachable — your approval on that specific call is what
  allows it. A path outside the project directory is flagged as such on the
  prompt. Relative paths resolve against `config :claudex_chat, default_root:`.
- **System directories and credential stores are refused outright**, whatever
  you approve: `/etc`, `/usr`, `/bin`, `~/.ssh`, `~/.aws`, `~/.gnupg` and
  similar. Add your own with `config :claudex_chat, denied_paths:`. Symlinks
  are resolved on both sides, so a link into a denied directory is refused
  too.
- **Web search runs on Anthropic's servers**, so it is the one tool without an
  approval step: it executes inside the API turn, where this app has no
  opportunity to pause it. Which variant is offered depends on the model's
  reported `code_execution` capability.
- **A stopped or failed reply can be retried.** Press Stop mid-stream, or hit
  an API error, and the reply gets a Retry button: it discards that reply —
  and anything after it — and asks again. There is no "resume": continuing a
  half-written reply needs an assistant-message prefill, which current models
  reject with a 400.
- **Cost is reported in tokens** — input, output, and cache reads, exactly as
  the API reported them, alongside the wall time from send to done. Counters
  the API didn't send are left out rather than shown as zero.

## Development

```sh
mix test        # no network, no API key needed
mix precommit   # compile --warnings-as-errors, unused deps, format, test
```

The test suite never calls the Claude API: `config/test.exs` sets
`config :claudex_chat, ClaudexChat.Models, refresh: false`, so the model
catalogue comes from the built-in list. Fixtures under `test/fixtures/` are
real recorded API payloads, copied from the SDK's own test suite.

See `CLAUDE.md` for the project's engineering rules and `AGENTS.md` for the
Phoenix and LiveView house style.

## License

MIT — see [LICENSE](LICENSE).
