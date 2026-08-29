defmodule LiveCeci.Tools do
  @moduledoc """
  Ceci's operational tools: scheduling, attendance, receipts, and the accountant's summary.

  The whole lesson of these tools: in a live session, function calls are SYNCHRONOUS —
  the model's voice pauses until the tool returns. So each handler does the minimum
  (decide an action for the browser) and returns INSTANTLY. It never awaits real work.

  That is why `dispatch/2` is a plain function over plain data: no GenServer call, no
  HTTP, no `Task.await`. If it ever needs to become one of those — and a real booking
  or a real invoice would — the call has to move off this path, or the voice will stall
  mid-sentence while it waits.

  ## The boundary is in the schema — for the part of it a schema can hold

  Ceci is operational only, never clinical. A prompt asking the model not to collect
  clinical detail is one instruction among many; a parameter list with nowhere to PUT a
  diagnosis or a session note is structural. So every patient here is a `paciente`
  bounded to `@patient_max` characters, `status` is an `enum`, and `dispatch/2` re-checks
  both rather than trusting that the provider enforced them.

  What that does NOT do — and an earlier version of this note overclaimed — is keep
  clinical content off the wire. Every word spoken into the microphone reaches the
  provider and is transcribed there, because that is what a voice agent is. The schema
  governs what Ceci can WRITE DOWN and act on; it has no opinion on what she hears. If
  the promise ever needs to cover transmission, it cannot be kept in this file.
  """

  # The descriptions used to be the only thing saying this, and a description is a
  # request. maxLength and enum are the same statements in a form the API validates and
  # dispatch/2 re-checks — because neither the model nor the provider is obliged to honour
  # a schema, and "iniciais ou apelido" is worth nothing if a full clinical note fits.
  @patient_max 40
  # Everything else is free text the person actually said — a date phrase, a month, an
  # amount. Bounded because the model decides it and nothing else does, but bounded far
  # above anything a human utters in one breath.
  @free_text_max 200
  @status_values ["compareceu", "faltou", "remarcou"]

  @declarations [
    %{
      name: "agendar_sessao",
      description:
        "Agenda uma sessão na agenda do terapeuta. Use quando pedirem para marcar, " <>
          "remarcar ou encaixar um horário.",
      parameters: %{
        type: "object",
        properties: %{
          paciente: %{
            type: "string",
            description: "iniciais ou apelido do paciente — nunca o nome completo",
            maxLength: @patient_max
          },
          quando: %{
            type: "string",
            description: "o horário como a pessoa falou, ex.: 'terça que vem às 14h'"
          }
        },
        required: ["paciente", "quando"]
      }
    },
    %{
      name: "confirmar_presenca",
      description: "Registra se o paciente compareceu, faltou ou remarcou uma sessão.",
      parameters: %{
        type: "object",
        properties: %{
          paciente: %{
            type: "string",
            description: "iniciais ou apelido do paciente — nunca o nome completo",
            maxLength: @patient_max
          },
          status: %{
            type: "string",
            description: "um de: compareceu, faltou, remarcou",
            enum: @status_values
          }
        },
        required: ["paciente", "status"]
      }
    },
    %{
      name: "emitir_recibo",
      description: "Emite o recibo de uma sessão já paga.",
      parameters: %{
        type: "object",
        properties: %{
          paciente: %{
            type: "string",
            description: "iniciais ou apelido do paciente — nunca o nome completo",
            maxLength: @patient_max
          },
          valor: %{type: "string", description: "o valor em reais, ex.: '250'"}
        },
        required: ["paciente", "valor"]
      }
    },
    %{
      name: "resumo_mensal",
      description: "Fecha o resumo do mês para o contador: sessões, faltas e recebimentos.",
      parameters: %{
        type: "object",
        properties: %{
          mes: %{type: "string", description: "o mês pedido, ex.: 'agosto' ou 'este mês'"}
        }
      }
    }
  ]

  @doc """
  The function declarations, shaped for the Live API `setup.tools` field.
  """
  @spec declarations() :: [map()]
  def declarations, do: @declarations

  @doc """
  The `tools` value for `Gemini.Live.Session.start_link/1`.
  """
  @spec live_tools() :: [map()]
  def live_tools, do: [%{function_declarations: @declarations}]

  @typedoc "An action the server forwards to the browser's activity panel, or `nil`."
  @type action :: %{required(:action) => String.t(), optional(:detail) => String.t()} | nil

  @doc """
  Returns `{action, function_result}`.

  `action` is forwarded to the browser as `{"type": "action", ...}` and drawn in the
  activity panel. `function_result` is handed straight back to the model — instantly,
  never blocking.

  Nothing here is persisted. These are stubs: the POC proves the voice loop, and a real
  booking would have to go somewhere other than this function. The result string is what
  the model reads back, so it says what happened, not that it succeeded.
  """
  @spec dispatch(String.t(), map()) :: {action(), map()}
  def dispatch("agendar_sessao", args) do
    paciente = arg(args, :paciente)
    quando = arg(args, :quando)

    complete([paciente: paciente, quando: quando], fn ->
      {%{action: "agendar", detail: join([paciente, quando])},
       %{result: "sessão agendada para #{quando}"}}
    end)
  end

  def dispatch("confirmar_presenca", args) do
    paciente = arg(args, :paciente)
    status = arg(args, :status)

    complete([paciente: paciente, status: status], fn ->
      if status in @status_values do
        {%{action: "presenca", detail: join([paciente, status])},
         %{result: "presença: #{status}"}}
      else
        {nil, %{result: "status tem de ser #{Enum.join(@status_values, ", ")}"}}
      end
    end)
  end

  def dispatch("emitir_recibo", args) do
    paciente = arg(args, :paciente)
    valor = arg(args, :valor)

    complete([paciente: paciente, valor: valor], fn ->
      {%{action: "recibo", detail: join([paciente, money(valor)])}, %{result: "recibo emitido"}}
    end)
  end

  # The only tool with nothing required: "fecha o resumo" with no month is a fair request.
  def dispatch("resumo_mensal", args) do
    mes = arg(args, :mes)
    {%{action: "resumo", detail: mes}, %{result: "resumo fechado"}}
  end

  def dispatch(name, _args), do: {nil, %{result: "unknown tool: #{name}"}}

  # Runs the tool only if every required argument survived coercion.
  #
  # This is the half that matters. Coercing a map to "" stops the crash, but it used to
  # leave `emitir_recibo` answering "recibo emitido" with no patient, and Ceci says that
  # out loud. Emitting no action and naming the missing field lets her ask again, which
  # is what a person would do. A confirmation for something that did not happen is worse
  # than an error.
  defp complete(required, run) do
    case for({field, ""} <- required, do: field) do
      [] -> run.()
      missing -> {nil, %{result: "faltou #{Enum.join(missing, " e ")} — pergunte de novo"}}
    end
  end

  # The model decides these keys, so they arrive as strings from JSON and as atoms from
  # gemini_ex's structs. Both, or an empty string — never a crash on the voice path.
  #
  # Takes the ATOM and derives the string, not the other way round. The reverse — which
  # this used to do — calls String.to_atom/1 on the voice path. The argument was always
  # a literal from the line above, so it was never an exhaustion risk, but the shape
  # invites one the first time somebody passes it a key the model chose.
  # :paciente carries the tighter bound; every other field gets the free-text one. The
  # limit is per field on purpose — an earlier version capped everything at 40 and
  # quietly truncated "toda terça-feira do mês que vem às quatorze horas".
  defp arg(args, :paciente = key), do: fetch(args, key, @patient_max)
  defp arg(args, key), do: fetch(args, key, @free_text_max)

  defp fetch(args, key, max) when is_map(args) and is_atom(key) do
    args
    |> Map.get(key, Map.get(args, Atom.to_string(key)))
    |> coerce(max)
  end

  defp fetch(_args, _key, _max), do: ""

  # The model decides the VALUES too, and it does not always send a string. Declaring a
  # parameter `type: "string"` is a request, not a guarantee. Three shapes were measured
  # reaching here:
  #
  #   %{"iniciais" => "A.B."}  raised Protocol.UndefinedError in join/1 — on the WebSockex
  #                            process for Grok, inside gemini_ex's Session for Gemini.
  #                            Either way the live call dies mid-sentence, steerable by
  #                            anyone with a microphone.
  #   ["A", "B"]               did NOT raise. Enum.join flattened it to "AB" and Ceci
  #                            confirmed a booking out loud against a mangled name.
  #   8                        passed straight through into a field @type calls String.t().
  #
  # The silent two are worse than the crash. Numbers coerce, because a model emitting
  # `mes: 8` is being reasonable; anything structural becomes "" and the caller reports
  # it rather than guessing what was meant.
  # Truncated, not rejected. An over-long field is the model misunderstanding the schema,
  # not an attack, and refusing the whole turn over it would be worse UX than cutting it —
  # but letting a clinical paragraph through in a field documented as initials is the one
  # thing this app promises never to do.
  # Two bounds, and the second one is not obvious.
  #
  # byte_size/1 is O(1) and UTF-8 never uses fewer bytes than characters, so a string
  # already inside the limit is returned untouched without counting graphemes.
  #
  # The over-long path cannot call String.slice/3 directly: measured, it walks the WHOLE
  # binary rather than stopping at `max` graphemes — 25_316 reductions for a 200_000-char
  # argument, against 301 for binary_part. The model chooses that length, so that is
  # unbounded work on the voice path, sitting behind a tool call that pauses her mid
  # sentence. Cutting a byte prefix first bounds the whole thing by `max`: a UTF-8
  # grapheme is at most 4 bytes, so max * 4 bytes always contains at least `max` of them.
  defp coerce(value, max) when is_binary(value) do
    if byte_size(value) <= max do
      value
    else
      value
      |> binary_part(0, min(byte_size(value), max * 4))
      |> whole_graphemes()
      |> String.slice(0, max)
    end
  end

  defp coerce(value, _max) when is_integer(value) or is_float(value), do: to_string(value)
  defp coerce(_other, _max), do: ""

  # binary_part/3 counts bytes, so it can land in the middle of a multi-byte character
  # and hand String.slice/3 invalid UTF-8. At most three bytes ever need dropping.
  defp whole_graphemes(""), do: ""

  defp whole_graphemes(binary) do
    if String.valid?(binary),
      do: binary,
      else: whole_graphemes(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # arg/2 returns "" and never nil, so `valor && ...` here was dead truthiness the
  # compiler is right to reject.
  defp money(""), do: ""
  defp money(valor), do: "R$ #{valor}"

  defp join(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end
end
