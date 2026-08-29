defmodule LiveCeci.ToolsTest do
  use ExUnit.Case, async: true

  alias LiveCeci.Tools

  describe "dispatch/2" do
    test "agendar_sessao returns the action and answers the model with what it did" do
      assert {%{action: "agendar", detail: "M.S. · terça às 14h"},
              %{result: "sessão agendada para terça às 14h"}} =
               Tools.dispatch("agendar_sessao", %{
                 "paciente" => "M.S.",
                 "quando" => "terça às 14h"
               })
    end

    test "confirmar_presenca carries the status through to both halves" do
      assert {%{action: "presenca", detail: "R.L. · faltou"}, %{result: "presença: faltou"}} =
               Tools.dispatch("confirmar_presenca", %{"paciente" => "R.L.", "status" => "faltou"})
    end

    test "emitir_recibo formats the amount as money for the panel" do
      assert {%{action: "recibo", detail: "A.Q. · R$ 250"}, %{result: "recibo emitido"}} =
               Tools.dispatch("emitir_recibo", %{"paciente" => "A.Q.", "valor" => "250"})
    end

    test "resumo_mensal is the one tool that needs no patient at all" do
      assert {%{action: "resumo", detail: "agosto"}, %{result: "resumo fechado"}} =
               Tools.dispatch("resumo_mensal", %{"mes" => "agosto"})
    end

    test "a missing argument reports back instead of confirming something that did not happen" do
      # It used to answer "recibo emitido" with no patient, and Ceci says the result out
      # loud. No action reaches the browser and the model is told which field to ask for.
      assert {nil, %{result: "faltou quando — pergunte de novo"}} =
               Tools.dispatch("agendar_sessao", %{"paciente" => "M.S."})

      assert {nil, %{result: "faltou paciente e valor — pergunte de novo"}} =
               Tools.dispatch("emitir_recibo", %{})
    end

    test "a non-string argument neither crashes the call nor corrupts it silently" do
      # The model decides the values, and `type: "string"` in the schema is a request.
      # All three of these were measured coming back from a live model shape:
      #
      #   a map raised Protocol.UndefinedError on the WebSockex process, killing the call
      #   a list did NOT raise — Enum.join flattened ["A","B"] into "AB"
      #   an integer passed through into a field @type declares as String.t()
      #
      # The quiet two were the dangerous ones: she confirmed a booking against mangled data.
      assert {nil, %{result: "faltou paciente" <> _}} =
               Tools.dispatch("agendar_sessao", %{
                 "paciente" => %{"iniciais" => "A.B."},
                 "quando" => "terça"
               })

      assert {nil, %{result: "faltou paciente" <> _}} =
               Tools.dispatch("confirmar_presenca", %{
                 "paciente" => ["A", "B"],
                 "status" => "faltou"
               })

      # A number is the one non-string worth keeping: `mes: 8` is a reasonable emission.
      assert {%{action: "resumo", detail: "8"}, _result} =
               Tools.dispatch("resumo_mensal", %{"mes" => 8})
    end

    test "atom-keyed args work too" do
      # gemini_ex hands them over as atoms, xAI as strings after Jason.decode.
      assert {%{action: "presenca", detail: "J.P. · compareceu"}, _result} =
               Tools.dispatch("confirmar_presenca", %{paciente: "J.P.", status: "compareceu"})
    end

    test "an unknown tool tells the model so, and emits no action" do
      assert {nil, %{result: "unknown tool: teleport"}} = Tools.dispatch("teleport", %{})
    end
  end

  describe "the operational-only boundary" do
    # Ceci is operational, never clinical. The prompt says so, but a prompt is one
    # instruction among many — this asserts the same thing structurally, where the model
    # cannot argue with it. If a future tool grows a `notas` or `diagnostico` parameter,
    # this fails before anyone has to notice it in a transcript.
    @clinical ~w(nota notas anotacao anotação prontuario prontuário diagnostico diagnóstico
                 sessao_conteudo queixa sintoma laudo evolucao evolução)

    test "no tool has a parameter that could hold clinical content" do
      for %{name: name, parameters: %{properties: properties}} <- Tools.declarations(),
          {field, _schema} <- properties do
        refute to_string(field) in @clinical,
               "#{name} declares #{field}, which invites clinical content into an operational tool"
      end
    end

    test "patients are identified by initials or nickname, and the schema says so" do
      for %{name: name, parameters: %{properties: properties}} <- Tools.declarations(),
          %{description: description} = properties[:paciente] || %{description: nil},
          description != nil do
        assert description =~ "iniciais",
               "#{name} takes a patient without telling the model to keep it to initials"
      end
    end
  end

  describe "the instant-return rule" do
    # Live function calls are SYNCHRONOUS: the model's voice is paused until the tool
    # returns. This is the guardrail from DESIGN.md §10, and it takes two measurements
    # because neither one catches both failure modes:
    #
    #   Process.sleep(60)          60_109 µs but only 6 reductions  -> wall clock only
    #   File.read! of a small file     40 µs and     40 reductions  -> reductions only
    #
    # So wall clock guards against blocking (sleep, network, GenServer.call) and
    # reductions guard against work (parsing, iterating, reading files).
    #
    # It matters more now than it did for the music tools. "Agendar" and "emitir recibo"
    # SOUND like they should hit a database, and the first person to make one real will
    # reach for this function. These two tests are what tells them not to.
    @cases [
      {"agendar_sessao", %{"paciente" => "M.S.", "quando" => "terça que vem às 14h"}},
      {"confirmar_presenca", %{"paciente" => "R.L.", "status" => "compareceu"}},
      {"emitir_recibo", %{"paciente" => "A.Q.", "valor" => "250"}},
      {"resumo_mensal", %{"mes" => "agosto"}}
    ]

    # Wall clock is the only instrument that sees a blocked scheduler, but it also sees
    # every unrelated stall on the machine. Now that reductions cover the work side, this
    # half only has to catch blocking, and the cheapest realistic offender — a GenServer
    # call, an HTTP request, a sleep — is orders of magnitude past 50 ms.
    @budget_us 50_000

    test "no tool blocks the voice" do
      # Best of three, not a single shot. This half exists to catch BLOCKING — a sleep, a
      # GenServer.call, an HTTP request — and every one of those is slow on every run.
      # A single measurement also sees whatever else the machine was doing that
      # millisecond, which is not a property of this code. Taking the minimum keeps the
      # signal and drops the noise, which is how you time anything.
      for {name, args} <- @cases do
        elapsed =
          1..3
          |> Enum.map(fn _ -> elem(:timer.tc(fn -> Tools.dispatch(name, args) end), 0) end)
          |> Enum.min()

        assert elapsed < @budget_us,
               "#{name} took #{elapsed}µs at best of three — a live tool call must return " <>
                 "instantly or the voice stalls"
      end
    end

    # Reductions are immune to machine load, so this half never flakes.
    #
    # Measured after the argument-coercion fix: 64, 64, 66, 16 for the four clauses, and
    # 69 for the worst case (every required argument missing, so `complete/2` builds the
    # error). 90 is deliberately tight rather than round. The reference offender in the
    # comment above — File.read! of a small file — costs about 40, so this headroom is
    # smaller than the cheapest thing the test exists to catch. Raising it to a
    # comfortable 150 would let a file read slip through unnoticed.
    @budget_reductions 90

    test "the cost does not grow with the size of what the model sends" do
      # The property that matters, and a flat budget cannot express it. The model chooses
      # these strings; if the work is proportional to their length, a long one stalls her
      # voice, because a live function call pauses it until the tool returns.
      #
      # This caught a real one. coerce/2 used String.slice/3 to truncate, which walks the
      # WHOLE binary instead of stopping at the limit — 25_316 reductions for a 200_000
      # character argument against 301 for binary_part. Bounding by a byte prefix first
      # made it flat.
      cost = fn chars ->
        args = %{"paciente" => "M.S.", "quando" => String.duplicate("á", chars)}
        {:reductions, before} = Process.info(self(), :reductions)
        Tools.dispatch("agendar_sessao", args)
        {:reductions, now} = Process.info(self(), :reductions)
        now - before
      end

      small = cost.(200)
      huge = cost.(2_000_000)

      # Ten thousand times the input, and the work must not even double. Measured flat:
      # 1219 -> 1643.
      assert huge < small * 2,
             "dispatch cost #{small} reductions on 200 characters and #{huge} on 2_000_000 — " <>
               "the truncation is walking the input instead of bounding it"
    end

    test "no tool does real work" do
      for {name, args} <- @cases do
        {:reductions, before} = Process.info(self(), :reductions)
        Tools.dispatch(name, args)
        {:reductions, now} = Process.info(self(), :reductions)

        assert now - before < @budget_reductions,
               "#{name} burned #{now - before} reductions — dispatch must stay a pattern match over plain data"
      end
    end
  end

  describe "declarations/0" do
    test "declares exactly the four operational tools the persona promises" do
      names = Enum.map(Tools.declarations(), & &1.name)

      assert Enum.sort(names) ==
               ["agendar_sessao", "confirmar_presenca", "emitir_recibo", "resumo_mensal"]
    end

    test "every declared tool has a dispatch clause" do
      # The failure this catches: renaming a tool in @declarations and not in dispatch/2.
      # Both compile, and the only symptom is the model calling a tool that answers
      # "unknown tool" while she cheerfully says it is done.
      #
      # Called with no arguments on purpose. Most clauses now refuse and report a missing
      # field, which is a different answer from falling through to the unknown clause —
      # and telling those two apart is exactly the point.
      for %{name: name} <- Tools.declarations() do
        assert {_command, %{result: result}} = Tools.dispatch(name, %{})

        refute result =~ "unknown tool",
               "#{name} is declared but falls through to the unknown clause"
      end
    end

    test "every declared tool emits an action when its arguments are complete" do
      complete = %{
        "agendar_sessao" => %{"paciente" => "M.S.", "quando" => "terça"},
        "confirmar_presenca" => %{"paciente" => "M.S.", "status" => "compareceu"},
        "emitir_recibo" => %{"paciente" => "M.S.", "valor" => "250"},
        "resumo_mensal" => %{"mes" => "agosto"}
      }

      for %{name: name} <- Tools.declarations() do
        args = Map.fetch!(complete, name)
        assert {%{action: _}, %{result: _}} = Tools.dispatch(name, args)
      end
    end

    test "tool names are ASCII — the APIs validate them" do
      for %{name: name} <- Tools.declarations() do
        assert name =~ ~r/^[a-z0-9_]+$/,
               "#{name} is not plain ASCII snake_case; both APIs reject names that are not"
      end
    end

    test "live_tools/0 wraps them the way setup.tools expects" do
      assert [%{function_declarations: declarations}] = Tools.live_tools()
      assert declarations == Tools.declarations()
    end

    test "declarations survive a JSON round-trip to the API" do
      # The descriptions carry accented Portuguese now, which is exactly the sort of
      # thing that survives Elixir and dies at an encoder boundary.
      assert Tools.declarations() |> Jason.encode!() |> Jason.decode!() |> length() == 4
    end
  end
end
