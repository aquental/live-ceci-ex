# Security & Privacy Audit — clinic snapshot layer (commit 2f3d902)

**Scope**: `lib/live_ceci/data.ex`, `lib/live_ceci/clinic.ex`, `lib/live_ceci/clock.ex`,
`priv/data/clinic.json`, the changed parts of `lib/live_ceci/tools.ex`, and the two
`dispatch/2` call sites (`provider/grok.ex:292`, `provider/gemini.ex:178`).

**Verification note, read this first**: this session had **no Bash tool** — `Read`,
`Grep`, `Glob` and `Write` only. Nothing below was verified by EXECUTION. Every finding
is marked either **[source]** (traced by reading the code and the library/OTP semantics
it depends on) or **[reasoning]** (an inference I could not close by reading). Where a
finding would be settled by running something, I say what to run.

---

## Summary of the posture change this commit makes

Before 2f3d902 every tool was a stub: `/ws` cost API quota and nothing else. After it,
four tools read a real clinic snapshot and one writes it. Two consequences that no
moduledoc in the changed files accounts for:

1. The **function result** of a tool is not a local value — it is handed to xAI/Google
   and spoken. `listar_pacientes` and `listar_sessoes_hoje` now put a therapy
   practice's patient roster and today's appointment schedule on that wire.
2. The **unauthenticated** `/ws` endpoint now reads out that roster to anyone who
   reaches it. `config/runtime.exs:80-83` still describes the `BIND_IP=0.0.0.0` risk as
   quota spend only. That assessment is now stale.

Clean: no `String.to_atom`, no `raw/1`, no `binary_to_term`, no SQL, no path built from
model input (`Data.expand_path/1` takes a compile/boot-time config value only), no
unbounded map growth through `close_month/2` (it can only rewrite a month key that
already exists — `clinic.ex:68` and `clinic.ex:82` both gate on presence), no
credential in the new code, no logging from the new modules.

---

## P1 — `/ws` now discloses the patient roster, and the documented threat model says it does not

- **Severity**: P1 (data exposure + stale security documentation)
- **Location**: `lib/live_ceci/tools.ex:219-228`, `lib/live_ceci/tools.ex:230-245`,
  `config/runtime.exs:80-83`
- **Verified**: [source] — traced `dispatch/2` from `Router` → `Socket` → provider;
  confirmed `/ws` has a ticket, an `Origin` check and a session cap, and no
  authentication of any kind (`lib/live_ceci/router.ex:247-311`,
  `lib/live_ceci/sessions.ex`).

`config/runtime.exs:80-83` reads:

> Bandit's own default is 0.0.0.0, which on a laptop on café wifi puts an
> unauthenticated WebSocket in front of a metered API on the open LAN: /ws has no origin
> check and no auth, and every frame it accepts spends the API key's quota.

That was an accurate risk statement when every tool was a stub. It is not one now. With
`BIND_IP=0.0.0.0`, a LAN peer that passes the `Origin` check obtains a session, says
"quem são os pacientes?" and "quem vem hoje?", and receives — spoken aloud and mirrored
into the browser action panel — the practice's full patient list and today's schedule of
who is in therapy at what hour. The cost of an open bind went from *money* to *a
sensitive-personal-data breach*.

**Failure scenario**: therapist sets `BIND_IP=0.0.0.0` to demo Ceci from a phone, on
clinic wifi. Anyone on that network reads the roster and the day's appointment times.

**Fix**:
1. Update the `runtime.exs` comment — the value of the warning is that it is true. It
   should now say the endpoint discloses patient data, not quota.
2. `BIND_IP != 127.0.0.1` should require a shared secret on the ticket endpoint before
   the data-reading tools are enabled, or the data tools should be gated behind a
   config flag that defaults off when the bind is non-loopback.

---

## P2 — the patient roster leaves the machine when the browser panel would have been enough

- **Severity**: P2 (privacy / third-party transfer, LGPD sensitive data)
- **Location**: `lib/live_ceci/tools.ex:219-228` (`listar_pacientes`),
  `lib/live_ceci/tools.ex:230-245` (`listar_sessoes_hoje`)
- **Verified**: [source] — `dispatch/2` returns `{action, function_result}`;
  `grok.ex:292-295` sends `result` upstream in `conversation.item.create` and sends
  `command` to the socket owner. The two destinations are genuinely separate.

**Confirming your item 2: yes, this is a real privacy finding.** "M.S. attends therapy
at 09:00 today" is health data about an identifiable person under LGPD Art. 5 II / Art.
11 — pseudonymisation to initials reduces, but does not remove, identifiability when it
is paired with a specific clinic and a specific hour. This commit is the first time any
of it is transmitted to a third-party processor, and there is nothing in the repo
recording a data-processing agreement, a retention setting, or a train-on-my-data
opt-out with xAI or Google.

Two things make this worse than it needs to be:

**(a) The read path has none of the discipline the write path has.** `tools.ex:33-38`
and `coerce/2` bound, re-check and truncate every value the *model* supplies, and the
moduledoc at `tools.ex:14-26` explains why a schema is stronger than a prompt. Nothing
equivalent guards the values going *out*. `& &1["apelido"]` (`tools.ex:223`) emits
whatever string is in the JSON, at any length, unvalidated. The one structural promise
this app makes — "iniciais ou apelido, nunca o nome completo" — is enforced on input
and merely *hoped for* on output.

`priv/data/clinic.json:6` and `:9` already break it: `"João"` and `"Ana"` are given
names, not initials or a nickname. The fixture the product ships with violates the
product's own boundary, on the path that leaves the machine.

**(b) The architecture already has a channel that does not leave the machine, and it is
unused for this.** The `action` half of the tuple goes to the browser panel only. The
roster does not need to reach the model at all — the model needs to *know it answered*,
the human needs to *see the list*.

**Fix**:

```elixir
def dispatch("listar_pacientes", _args) do
  apelidos = LiveCeci.Data.get_data() |> LiveCeci.Clinic.patients() |> Enum.map(&label/1)

  case apelidos do
    [] -> {nil, %{result: "nenhum paciente"}}
    list ->
      # The names go to the screen. The model gets a count, and says "está na tela".
      {%{action: "pacientes", detail: join(list)},
       %{result: "#{length(list)} pacientes — mostrei a lista na tela"}}
  end
end

# The outbound twin of coerce/2: the boundary is enforced on the way out too.
defp label(%{"apelido" => a}) when is_binary(a), do: coerce(a, @patient_max)
defp label(_), do: ""
```

Plus: rename `"João"` → `"J.M."` and `"Ana"` → `"A.N."` in `priv/data/clinic.json`, and
add a test asserting no outbound patient label exceeds `@patient_max`.

For `listar_sessoes_hoje` the same trick works less cleanly — the therapist genuinely
wants "M.S. às nove" spoken. If names must go upstream there, that is a deliberate trade
and should be written down as one, next to a note on provider retention settings.

---

## P2 — `fechar_mes` is a read-modify-write with no atomicity, and `:already_closed` is therefore advisory

- **Severity**: P2
- **Location**: `lib/live_ceci/tools.ex:251-255`; `lib/live_ceci/data.ex:38-52`;
  `lib/live_ceci/clinic.ex:45-61`
- **Verified**: [source] for the mechanism (three separate ETS operations on a
  `:public` table with no lock and no CAS; `put_data/1` at `data.ex:50` replaces the
  entire snapshot row). [reasoning] for the probability — I could not measure the
  window. `MAX_SESSIONS` defaults to 8 (`limits.ex:52`), so concurrency is real.

**Confirming your item 1: yes, it is a genuine lost-update, and the `:already_closed`
guard at `clinic.ex:47` is not a guarantee.** Two interleavings:

- *Same month, two sessions*: both read `status: "open"`, both take the `{:ok, ...}`
  branch, both write. The end state is correct (closed), but **both callers hear "mês
  fechado, dados encaminhados ao contador"**. The duplicate-send guard did not fire. The
  moment `fechar_mes` stops being in-memory and actually emails the accountant, that is
  a duplicate submission with no detection.
- *Different months, two sessions*: A reads, B reads, A writes `julho: closed`, B writes
  a snapshot derived from its **stale** read — `julho` reverts to open, silently, while A
  has already told its user the month was closed.

I want to be honest about severity: the window is a handful of microseconds and today's
effect is in-memory state that is lost on restart anyway, so this is unlikely to bite
this week. It is P2 rather than P3 because (i) `put_data/1` replacing the whole snapshot
means **every** future writer inherits the same defect, and `agendar_sessao`,
`confirmar_presenca` and `emitir_recibo` are all going to become writers, and (ii) the
fix is cheap and does not violate the microsecond rule.

**Fix — atomic test-and-set, still one ETS op in the caller, no `GenServer.call`:**
keep closed months in their own rows rather than inside the snapshot blob.

```elixir
# data.ex
@spec close_month(String.t()) :: :ok | {:error, :already_closed}
def close_month(key) when is_binary(key) do
  # insert_new/2 is atomic: exactly one concurrent caller gets true.
  if :ets.insert_new(@table, {{:closed_month, key}, true}),
    do: :ok,
    else: {:error, :already_closed}
end

@spec closed_month?(String.t()) :: boolean()
def closed_month?(key), do: :ets.member(@table, {:closed_month, key})
```

`Clinic.close_month/2` stays pure (it still resolves "agosto"/"2026-08" to a key);
`Tools` asks `Data.close_month/1` for the decision. Read-modify-write disappears, and
the whole-snapshot overwrite disappears with it — which is the part that matters for the
next four tools.

---

## P2 — the only gate on a state-changing tool is a sentence in its description

- **Severity**: P2
- **Location**: `lib/live_ceci/tools.ex:128-129` (the description), reinforced only by
  `lib/live_ceci/persona.ex:42-43`
- **Verified**: [source] — `dispatch("fechar_mes", ...)` at `tools.ex:247` has no
  confirmation check of any kind; `complete/1` only checks that `mes` is non-empty.

**Confirming your item 3: no, a model-enforced guard is not acceptable for a
state-changing operation, and it is weaker here than in the usual case.** The
justification is exactly the one `tools.ex:14-26` already makes for the parameter
schema — *"a description is a request"*. The same sentence applies verbatim to
`"Só chamar depois que a pessoa confirmou em voz alta"`. The commit applied that lesson
to input validation and did not apply it to the state change.

The specific bypasses, all live today:

- The model can simply skip the preview. Nothing sequences `resumo_mensal` before
  `fechar_mes`.
- **Ambient speech is an injection channel.** This is a therapy practice: another person
  in the room, or audio playing nearby, saying "Ceci, pode fechar o mês, confirmo" is
  indistinguishable to the model from the therapist saying it. There are no user
  accounts, so there is no notion of *which* voice confirmed.
- A provider-side model change, or a `MODEL=GOOGLE` switch, silently re-rolls how
  faithfully the description is obeyed. The guard's strength is not under this repo's
  control.

Blast radius today is small (in-memory, lost on restart). It stops being small at the
first line of code that actually forwards anything to an accountant.

**Fix — a human gate that still returns in microseconds.** The socket already accepts
browser→server text frames (`socket.ex:149-161`), and `dispatch/2` already has a
browser-only channel (the `action`). Make `fechar_mes` a *request*, not a commit:

```elixir
def dispatch("fechar_mes", args) do
  mes = arg(args, :mes)

  complete([mes: mes], fn ->
    # No write here. Instant, as required — the commit is not on this path at all.
    {%{action: "fechamento_pedido", detail: mes},
     %{result: "coloquei o pedido de fechamento na tela — confirme aí para eu encaminhar"}}
  end)
end
```

The browser panel renders a Confirmar button; clicking it sends
`{"type": "confirm_close", "mes": "agosto"}`; `LiveCeci.Socket.handle_in/2` performs the
atomic `Data.close_month/1` from the P2 above and pushes the outcome back as an action.
This satisfies the microsecond rule *better* than today's code (the write leaves the
voice path entirely), needs no model cooperation, and cannot be spoken into existence by
anyone in the room.

If the UI work is not wanted now, the weaker fallback is a two-phase nonce in ETS keyed
by the caller pid — first `fechar_mes` records `{pid, mes, ts}` and answers "confirma?",
a second call within 60 s commits. Both are single ETS ops. It only forces two model
turns rather than one, so it is a speed bump, not a gate; prefer the browser handshake.

---

## P2 — a bad `clinic.json` at restart takes down every live call, not just the snapshot

- **Severity**: P2 (availability)
- **Location**: `lib/live_ceci/data.ex:86-100` (`init/1`, `File.read!` + `Jason.decode!`
  at `:92-96`); `lib/live_ceci/application.ex:12-36`
- **Verified**: [source] for the code path and for `Supervisor`'s documented defaults
  (`max_restarts: 3`, `max_seconds: 5`, and a supervisor that exceeds its restart
  intensity terminates all children and exits). **[reasoning]** for the end-to-end
  cascade — I could not execute it. To settle it: start the app, `File.write!` garbage
  into `priv/data/clinic.json` (or `File.rm!` it), then
  `Process.exit(Process.whereis(LiveCeci.Data), :kill)` four times inside five seconds
  and observe whether Bandit is still listening.

**Confirming your item 4, with a correction to the framing.** At *boot* the raise is
fine and arguably right — the app refuses to start, loudly, which is what you want for a
malformed data file. The problem is the *restart* case. `LiveCeci.Data` sits under a
`:one_for_one` supervisor with default intensity. If the file has been deleted, rotated,
or half-written by an editor while the node is up, and `Data` restarts for any reason,
`init/1` raises on every attempt; after three failures in five seconds
`LiveCeci.Supervisor` gives up and terminates **all** its children — including `Bandit`.
Every live therapy-session call drops mid-sentence because a JSON file was being edited.

The `data.ex:10-12` moduledoc documents the *data* consequence of a crash ("rebuilds
from the file and loses in-memory closes"). It does not document the *availability*
consequence, and the reasoning it does give assumes the rebuild succeeds.

Secondary, same area: `init/1` also does blocking disk I/O and JSON decoding inside a
supervisor's synchronous start, so every restart stalls the supervisor for the duration.
Minor at this file size; worth knowing.

**Fix**: degrade instead of cascading. Boot-time strictness can be kept explicitly.

```elixir
def init(_opts) do
  :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  data =
    try do
      :live_ceci
      |> Application.fetch_env!(:clinic_source)
      |> load_source()
      |> rewrite_today(LiveCeci.Clock.today())
    rescue
      error ->
        # One dead file must not take Bandit with it. Ceci answers "não consegui ler a
        # agenda" and every live call survives.
        Logger.error("clinic snapshot unreadable, starting empty: #{Exception.message(error)}")
        @empty
    end

  :ets.insert(@table, {@snapshot_key, data})
  {:ok, %{}}
end
```

...but see P3 below: `@empty` currently makes an unreadable file *indistinguishable from
an empty practice*, so this fix needs the degraded state to be visible.

---

## P3 — `get_data/0` raises if the table is gone, on the WebSockex process, mid-sentence

- **Severity**: P3 (narrow window, real crash)
- **Location**: `lib/live_ceci/data.ex:39`; test `test/live_ceci/data_test.exs:43-52`
- **Verified**: [source] — `:ets.lookup/2` on a name that is not a live table raises
  `ArgumentError` (documented Erlang behaviour); the table is owned by the `Data`
  process (`data.ex:90`) and so is destroyed when it dies. `grok.ex:283-295` calls
  `dispatch/2` directly on the WebSockex process.

Between the `Data` process dying and its replacement reaching `:ets.new/2` — a window
that includes the supervisor's restart scheduling — any concurrent `get_data/0` raises
inside the provider's socket process and kills the live call. `data.ex:5` promises
`get_data/0` is "an `:ets.lookup` in the caller"; it does not promise the table exists.

Worth flagging specifically because **the test that looks like it covers this does
not**. `data_test.exs:43` is named *"an empty table returns the empty snapshot, never
raises"*, but it calls `:ets.delete_all_objects/1` — it empties the table, it does not
remove it. The missing-table case is untested and the test name reads as if it were
covered.

**Fix** — still two ETS ops, still microseconds:

```elixir
def get_data do
  case :ets.whereis(@table) do
    :undefined ->
      @empty

    table ->
      case :ets.lookup(table, @snapshot_key) do
        [{@snapshot_key, data}] -> data
        [] -> @empty
      end
  end
end
```

and rename the existing test, adding a real one that does `:ets.delete(Data)`.

---

## P3 — a data-layer failure is spoken as a confident fact

- **Severity**: P3 (integrity of what Ceci says)
- **Location**: `lib/live_ceci/data.ex:41` (`[] -> @empty`),
  `lib/live_ceci/tools.ex:226`, `lib/live_ceci/tools.ex:243`
- **Verified**: [source].

Every failure in the snapshot layer collapses to the same value as a legitimately empty
practice. Ceci then says *"nenhum paciente"* or *"nenhuma sessão hoje"* — in her normal
confident voice, with no hedge. The therapist has no way to tell "you have no
appointments" from "I could not read your calendar", and the second one is the answer
that makes them not show up for a patient.

This is the same principle `complete/1` already encodes at `tools.ex:278-283` — *"A
confirmation for something that did not happen is worse than an error"* — applied to
reads instead of writes. The commit applied it to missing arguments and not to missing
data.

**Fix**: distinguish the two. Have `get_data/0` return `{:ok, data} | :unavailable` (or
set a `:degraded` flag row at `init/1` when the rescue above fires) and have the tools
answer *"não consegui ler a agenda agora"* rather than *"nenhuma sessão hoje"*.

---

## P3 — `rewrite_today/2` runs once at boot, so "today" rots at the first midnight

- **Severity**: P3 (correctness, but it produces confidently wrong speech)
- **Location**: `lib/live_ceci/data.ex:96` (called from `init/1` only);
  `lib/live_ceci/tools.ex:236` (`Clock.today()` is evaluated per call)
- **Verified**: [source] — `rewrite_today/2` has exactly one production caller,
  `init/1`. `Clock.today/0` (`clock.ex:10`) returns `Date.utc_today()` fresh each call.

The `"today"` sentinel rows are frozen to the boot date. `Clock.today/0` advances. So a
node left running overnight — which is the normal case for a POC someone demos twice —
finds no sessions matching the new date and Ceci says *"nenhuma sessão hoje"* while four
appointments sit in the snapshot. Combined with the P3 above, that is the worst possible
shape: a stale-data bug wearing the same words as an empty day.

The `clock.ex:4-6` moduledoc accepts a *timezone* limitation (UTC vs
America/São_Paulo). It does not cover this — this is not an hours-offset issue, it is
the sentinel never being re-resolved.

**Fix**: resolve the sentinel at read time rather than at load time — drop
`rewrite_today/2` from `init/1` and have `Clinic.sessions_on/2` treat a `"today"` row as
matching the date it is given. That also removes the boot-date rows from
`month_rows/4`'s month arithmetic, where they currently inflate whichever month the node
happened to boot in.

---

## Non-findings — checked and clean

- No `String.to_atom/1` anywhere in the new code; `clinic.ex:6` states the rule and the
  code keeps it (JSON keys stay strings throughout).
- `Clinic.close_month/2` cannot inject a new month key: `clinic.ex:68` requires the key
  to already resolve to a map, and `clinic.ex:82` requires a `"year"` match. No unbounded
  map growth from model input.
- `Data.expand_path/1` (`data.ex:102-104`) builds a path from `:clinic_source`, a
  config value, never from model or client input. No traversal.
- `resolve_month/2` downcases a model string bounded to 200 bytes by `coerce/2`; no
  regex, no unbounded work.
- No new logging in `data.ex`/`clinic.ex`/`clock.ex`, so no patient data reaches the
  application log from these modules. (`LiveCeci.Redact` redacts *credentials* only, not
  patient data — relevant if anyone later adds a log line here.)
- No secrets, no `raw/1`, no `binary_to_term`, no SQL, no deserialisation of client data
  in scope.

---

## Recommended order

1. Fix the `runtime.exs:80-83` threat statement and gate the data tools behind a
   non-loopback check (P1) — it is a comment and a config guard, an hour of work.
2. Move the roster to the browser channel and bound outbound labels; fix `"João"` /
   `"Ana"` in the fixture (P2).
3. Replace the `fechar_mes` read-modify-write with `:ets.insert_new/2` (P2).
4. Make the `fechar_mes` confirmation a browser handshake (P2).
5. `try/rescue` in `Data.init/1` plus `:ets.whereis/1` in `get_data/0`, and make the
   degraded state audibly distinct from an empty practice (P2 + two P3s).
6. Resolve `"today"` at read time (P3).

## Tools the maintainer should run (this agent had no Bash)

- `mix sobelow --exit medium` — will be quiet on a non-Phoenix app, but confirms it.
- `mix deps.audit` / `mix hex.audit`.
- The two experiments named inline above: the supervisor-cascade repro for the
  `Data.init/1` finding, and a `:ets.delete(Data)` test for the `get_data/0` finding.
