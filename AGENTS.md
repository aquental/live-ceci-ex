<!-- ELIXIR-PHOENIX-REVIEW-GUIDELINES:START -->
<!-- Last updated: 2026-08-28 | Managed by /phx:init — edits inside markers are overwritten on --update -->

## Review guidelines

`live_dj` is a plain Elixir OTP app: Bandit + Plug.Router + a raw `WebSock` handler
bridging one browser socket to one Gemini Live session. No Phoenix, no Ecto, no
database, no Oban. Rules about LiveView, changesets, migrations, queries, money, and
background jobs do not apply here — do not report them.

- **P1** `String.to_atom/1` on user-controlled input — atom exhaustion DoS; require
  an allowlist or `String.to_existing_atom/1`.
- **P1** Upstream error detail reaching the browser — a `gemini_ex` failure reason can
  carry quota state or a URL with the API key in it. Detail goes to `Logger`; the
  client gets a fixed string.
- **P2** Blocking calls in a `WebSock` callback — `handle_in/2` runs on the socket
  process and is the mic hot path. A `GenServer.call` there needs an explicit timeout
  and a `catch :exit`; see `LiveDJ.LiveSession`.
- **P2** Unsupervised long-lived processes — no bare `GenServer.start_link` /
  `Agent.start_link` outside a supervision tree in production code.

### Known non-issues (do NOT report these)

- `lib/live_dj/tools.ex` calls `String.to_atom/1` inside `arg/2`. The key is always a
  literal from a `dispatch/2` clause head (`"mood"`, `"title"`) — never the
  model-supplied tool name. Verified 2026-08-28, not an atom exhaustion vector.
- `lib/live_dj/socket.ex` calls `Session.start_link/1` outside a supervision tree.
  This is deliberate: the socket process owns its Live session, and the link is what
  makes the session die with the connection. Bandit supervises the socket process.

<!-- ELIXIR-PHOENIX-REVIEW-GUIDELINES:END -->
