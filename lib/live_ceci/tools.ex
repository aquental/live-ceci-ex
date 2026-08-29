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

  ## The boundary is in the schema, not just the prompt

  Ceci is operational only, never clinical. A prompt asking the model not to collect
  clinical detail is one instruction among many; a parameter list with nowhere to PUT a
  diagnosis or a session note is structural. So every patient here is a `paciente`
  documented as initials or a nickname, and no tool takes free text about a person.
  """

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
            description: "iniciais ou apelido do paciente — nunca o nome completo"
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
            description: "iniciais ou apelido do paciente — nunca o nome completo"
          },
          status: %{
            type: "string",
            description: "um de: compareceu, faltou, remarcou"
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
            description: "iniciais ou apelido do paciente — nunca o nome completo"
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

    {%{action: "agendar", detail: join([paciente, quando])},
     %{result: "sessão agendada para #{quando}"}}
  end

  def dispatch("confirmar_presenca", args) do
    paciente = arg(args, :paciente)
    status = arg(args, :status)

    {%{action: "presenca", detail: join([paciente, status])}, %{result: "presença: #{status}"}}
  end

  def dispatch("emitir_recibo", args) do
    paciente = arg(args, :paciente)
    valor = arg(args, :valor)

    {%{action: "recibo", detail: join([paciente, money(valor)])}, %{result: "recibo emitido"}}
  end

  def dispatch("resumo_mensal", args) do
    mes = arg(args, :mes)
    {%{action: "resumo", detail: mes}, %{result: "resumo fechado"}}
  end

  def dispatch(name, _args), do: {nil, %{result: "unknown tool: #{name}"}}

  # The model decides these keys, so they arrive as strings from JSON and as atoms from
  # gemini_ex's structs. Both, or an empty string — never a crash on the voice path.
  #
  # Takes the ATOM and derives the string, not the other way round. The reverse — which
  # this used to do — calls String.to_atom/1 on the voice path. The argument was always
  # a literal from the line above, so it was never an exhaustion risk, but the shape
  # invites one the first time somebody passes it a key the model chose.
  defp arg(args, key) when is_map(args) and is_atom(key) do
    args[key] || args[Atom.to_string(key)] || ""
  end

  defp arg(_args, _key), do: ""

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
