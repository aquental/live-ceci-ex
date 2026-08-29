defmodule LiveCeci.ToolsTest do
  # async: false — listar_*/resumo/fechar_mes read the named Data table.
  use ExUnit.Case, async: false

  alias LiveCeci.{Data, Tools}

  @clinic %{
    "patients" => [
      %{"id" => "p1", "apelido" => "M.S."},
      %{"id" => "p2", "apelido" => "R.L."}
    ],
    "sessions" => [
      %{"patient_id" => "p1", "date" => "2026-08-15", "time" => "09:00", "status" => "agendada"},
      %{"patient_id" => "p2", "date" => "2026-08-15", "time" => "14:00", "status" => "agendada"},
      %{"patient_id" => "p1", "date" => "2026-08-15", "time" => "16:00", "status" => "faltou"}
    ],
    "receipts" => [
      %{"patient_id" => "p1", "date" => "2026-08-15", "valor" => "250"}
    ],
    "months" => %{
      "julho" => %{"status" => "closed", "year" => 2026},
      "agosto" => %{"status" => "open", "year" => 2026}
    }
  }

  setup do
    original = Data.get_data()
    Data.reset(@clinic)
    on_exit(fn -> Data.reset(original) end)
    :ok
  end

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

    test "resumo_mensal is a preview, not a fake close" do
      assert {%{action: "resumo", detail: "agosto"},
              %{result: "agosto: 3 sessões, 1 faltas, 1 recebimentos"}} =
               Tools.dispatch("resumo_mensal", %{"mes" => "agosto"})

      refute elem(Tools.dispatch("resumo_mensal", %{"mes" => "agosto"}), 1).result =~ "fechado"
    end

    test "resumo_mensal says so when the month is already closed" do
      assert {%{action: "resumo", detail: "julho"}, %{result: result}} =
               Tools.dispatch("resumo_mensal", %{"mes" => "julho"})

      assert result =~ "já está fechado"
    end

    test "listar_pacientes joins apelidos" do
      assert {%{action: "pacientes", detail: "M.S. · R.L."}, %{result: "M.S. · R.L."}} =
               Tools.dispatch("listar_pacientes", %{})
    end

    test "listar_pacientes and listar_sessoes_hoje speak the empty state" do
      Data.reset(%{"patients" => [], "sessions" => [], "receipts" => [], "months" => %{}})

      assert {%{action: "pacientes"}, %{result: "nenhum paciente"}} =
               Tools.dispatch("listar_pacientes", %{})

      assert {%{action: "sessoes"}, %{result: "nenhuma sessão hoje"}} =
               Tools.dispatch("listar_sessoes_hoje", %{})
    end

    test "listar_sessoes_hoje joins apelido and time for Clock.today" do
      assert {%{action: "sessoes", detail: "M.S. 09h · R.L. 14h · M.S. 16h"},
              %{result: "M.S. 09h · R.L. 14h · M.S. 16h"}} =
               Tools.dispatch("listar_sessoes_hoje", %{})
    end

    test "fechar_mes writes the snapshot and refuses a second close" do
      assert {%{action: "fechamento", detail: "agosto"},
              %{result: "mês fechado, dados encaminhados ao contador"}} =
               Tools.dispatch("fechar_mes", %{"mes" => "agosto"})

      assert {nil, %{result: "esse mês já está fechado"}} =
               Tools.dispatch("fechar_mes", %{"mes" => "agosto"})
    end

    test "fechar_mes reports an unknown month instead of confirming" do
      assert {nil, %{result: "mês desconhecido — pergunte de novo"}} =
               Tools.dispatch("fechar_mes", %{"mes" => "setembro"})
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
      # "8" is not a month we know, so there is no action — but it must not crash.
      assert {nil, %{result: "mês desconhecido" <> _}} =
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
      {"resumo_mensal", %{"mes" => "agosto"}},
      {"listar_pacientes", %{}},
      {"listar_sessoes_hoje", %{}},
      {"fechar_mes", %{"mes" => "agosto"}}
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
          |> Enum.map(fn _ ->
            Data.reset(@clinic)
            elem(:timer.tc(fn -> Tools.dispatch(name, args) end), 0)
          end)
          |> Enum.min()

        assert elapsed < @budget_us,
               "#{name} took #{elapsed}µs at best of three — a live tool call must return " <>
                 "instantly or the voice stalls"
      end
    end

    # A ceiling PER TOOL, not one for all seven. The single 320 was calibrated against the
    # most expensive tool and was therefore useless for the other six: measured here,
    # listar_pacientes costs 50 reductions and a File.read! of priv/data/clinic.json costs
    # 39, so a file read added to it landed at 89 against a ceiling of 320. The guard the
    # docstring above describes was not guarding five of the seven tools it named.
    #
    # These are measured plus 25, which is under the 39 a file read costs, so the margin
    # is smaller than the cheapest thing this is meant to catch. Reductions are
    # deterministic — three runs gave identical counts — so tight is safe. If an OTP bump
    # moves them, this fails with the number to write down, which is the right failure.
    #
    # It already earned that: unifying the two month-resolution paths took resumo_mensal
    # from 225 to 295 and this test said so, which a shared 320 would have swallowed.
    @reduction_ceilings %{
      "agendar_sessao" => 91,
      "confirmar_presenca" => 91,
      "emitir_recibo" => 93,
      "listar_pacientes" => 76,
      "fechar_mes" => 205,
      "listar_sessoes_hoje" => 273,
      "resumo_mensal" => 320
    }

    # What the reduction ceiling is a PROXY for, asserted directly. Reductions conflate
    # work with data volume, so they can only ever approximate "does this touch the
    # world"; a call trace answers it.
    #
    # The tracer has to be a separate process — a process does not receive its own :call
    # trace messages, which is why the first version of this caught nothing and passed.
    @forbidden [File, :file, Jason, :gen_server, :httpc, :gen_tcp, :inet]

    defp calls_made(fun) do
      test = self()

      tracer =
        spawn(fn ->
          loop = fn loop, acc ->
            receive do
              {:trace, _pid, :call, {m, f, a}} -> loop.(loop, [{m, f, length(a)} | acc])
              {:dump, to} -> send(to, {:calls, Enum.uniq(acc)})
            end
          end

          loop.(loop, [])
        end)

      for m <- @forbidden, do: :erlang.trace_pattern({m, :_, :_}, true, [:local])
      :erlang.trace(test, true, [:call, {:tracer, tracer}])
      fun.()
      :erlang.trace(test, false, [:call])
      for m <- @forbidden, do: :erlang.trace_pattern({m, :_, :_}, false, [:local])

      send(tracer, {:dump, test})

      receive do
        {:calls, calls} -> calls
      after
        1_000 -> flunk("the tracer did not answer")
      end
    end

    test "the tracer would notice — the guard is checked against a known offender" do
      # A test for the test. Without this, a trace that silently caught nothing would make
      # the assertion below pass for every tool forever, which is exactly what the first
      # version of it did.
      caught = calls_made(fn -> File.read!("mix.exs") end)

      assert {File, :read!, 1} in caught,
             "the call tracer is not catching File.read!/1 — the next test proves nothing"
    end

    test "no tool touches the world" do
      for {name, args} <- @cases do
        Data.reset(@clinic)
        caught = calls_made(fn -> Tools.dispatch(name, args) end)

        assert caught == [],
               "#{name} called #{inspect(caught)} — dispatch runs inside the provider's " <>
                 "session process with the model's voice paused, so it must not touch " <>
                 "the filesystem, the network, or another process"
      end
    end

    test "no tool does real work" do
      # First call of a clause pays module-load; this test is about work, not that.
      for {name, args} <- @cases, do: Tools.dispatch(name, args)

      for {name, args} <- @cases do
        burned =
          1..3
          |> Enum.map(fn _ ->
            Data.reset(@clinic)
            {:reductions, before} = Process.info(self(), :reductions)
            Tools.dispatch(name, args)
            {:reductions, now} = Process.info(self(), :reductions)
            now - before
          end)
          |> Enum.min()

        ceiling = Map.fetch!(@reduction_ceilings, name)

        assert burned < ceiling,
               "#{name} burned #{burned} reductions against a ceiling of #{ceiling} — " <>
                 "dispatch must stay a pattern match over plain data"
      end
    end
  end

  describe "declarations/0" do
    test "declares exactly the operational tools the persona promises" do
      names = Enum.map(Tools.declarations(), & &1.name)

      assert Enum.sort(names) == [
               "agendar_sessao",
               "confirmar_presenca",
               "emitir_recibo",
               "fechar_mes",
               "listar_pacientes",
               "listar_sessoes_hoje",
               "resumo_mensal"
             ]
    end

    test "fechar_mes tells the model to wait for a spoken yes" do
      [%{description: description}] =
        Enum.filter(Tools.declarations(), &(&1.name == "fechar_mes"))

      assert description =~ "confirmou"
      assert description =~ "voz alta"
    end

    test "resumo_mensal says it is a preview and does not close" do
      [%{description: description}] =
        Enum.filter(Tools.declarations(), &(&1.name == "resumo_mensal"))

      assert description =~ "Não fecha"
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
        "resumo_mensal" => %{"mes" => "agosto"},
        "listar_pacientes" => %{},
        "listar_sessoes_hoje" => %{},
        "fechar_mes" => %{"mes" => "agosto"}
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
      assert Tools.declarations() |> Jason.encode!() |> Jason.decode!() |> length() == 7
    end
  end

  describe "fechar_mes under concurrency" do
    test "two sessions closing two different months do not clobber each other" do
      # Reproduced before the fix, with get_data + put_data: A closed agosto, B closed
      # setembro from a snapshot it had read a moment earlier, and B's write reverted
      # agosto to open — while both people were told "mês fechado, dados encaminhados ao
      # contador". One of those was not true, and nothing said so.
      #
      # Interleaved by hand rather than with Tasks, because the race is a property of the
      # read-decide-write sequence and not of the scheduler. Timing it would make this a
      # test that usually passes.
      two_months =
        Map.put(@clinic, "months", %{
          "agosto" => %{"status" => "open", "year" => 2026},
          "setembro" => %{"status" => "open", "year" => 2026}
        })

      Data.reset(two_months)

      stale = Data.get_data()
      assert {%{action: "fechamento"}, _} = Tools.dispatch("fechar_mes", %{"mes" => "agosto"})

      # B decides against `stale`, which no longer exists. The compare-and-swap refuses
      # it, dispatch re-reads, and setembro closes on top of the agosto that is already
      # closed rather than instead of it.
      assert {:stale, _} = {Data.replace(stale, stale), :b_would_have_won_before}
      assert {%{action: "fechamento"}, _} = Tools.dispatch("fechar_mes", %{"mes" => "setembro"})

      months = Data.get_data()["months"]
      assert months["agosto"]["status"] == "closed", "agosto was reverted by the second close"
      assert months["setembro"]["status"] == "closed"
    end

    test "closing the same month twice is refused, not double-reported" do
      Data.reset(@clinic)

      assert {%{action: "fechamento"}, _} = Tools.dispatch("fechar_mes", %{"mes" => "agosto"})

      assert {nil, %{result: "esse mês já está fechado"}} =
               Tools.dispatch("fechar_mes", %{"mes" => "agosto"})
    end

    test "a relative month is closable, because the schema says it is" do
      Data.reset(@clinic)

      assert {%{action: "fechamento", detail: "este mês"}, _} =
               Tools.dispatch("fechar_mes", %{"mes" => "este mês"})

      assert Data.get_data()["months"]["agosto"]["status"] == "closed"
    end
  end
end
