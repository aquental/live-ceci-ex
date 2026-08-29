defmodule LiveCeci.ClinicTest do
  use ExUnit.Case, async: true

  alias LiveCeci.Clinic

  # config/test.exs freezes the clock at this date. Clinic has no clock of its own — a
  # relative month like "este mês" is resolved against whatever date the caller passes,
  # which is what keeps the module pure and testable with map literals.
  @today ~D[2026-08-15]

  @data %{
    "patients" => [
      %{"id" => "p1", "apelido" => "M.S."},
      %{"id" => "p2", "apelido" => "R.L."}
    ],
    "sessions" => [
      %{"patient_id" => "p1", "date" => "2026-08-15", "time" => "09:00", "status" => "agendada"},
      %{"patient_id" => "p2", "date" => "2026-08-16", "time" => "14:00", "status" => "agendada"},
      %{"patient_id" => "p1", "date" => "2026-08-15", "time" => "16:00", "status" => "faltou"},
      %{"patient_id" => "p2", "date" => "2026-07-20", "time" => "10:00", "status" => "compareceu"}
    ],
    "receipts" => [
      %{"patient_id" => "p1", "date" => "2026-08-15", "valor" => "250"},
      %{"patient_id" => "p2", "date" => "2026-07-20", "valor" => "250"}
    ],
    "months" => %{
      "julho" => %{"status" => "closed", "year" => 2026},
      "agosto" => %{"status" => "open", "year" => 2026}
    }
  }

  test "patients/1 lists apelidos from the snapshot" do
    assert ["M.S.", "R.L."] == Enum.map(Clinic.patients(@data), & &1["apelido"])
  end

  test "sessions_on/2 filters by the given date and never consults the clock" do
    assert ["09:00", "16:00"] ==
             @data
             |> Clinic.sessions_on(~D[2026-08-15])
             |> Enum.map(& &1["time"])

    assert [%{"date" => "2026-08-16"}] = Clinic.sessions_on(@data, ~D[2026-08-16])
    assert [] = Clinic.sessions_on(@data, ~D[2026-01-01])
  end

  test "preview_month/3 counts sessions, faltas and receipts for a named month" do
    assert %{
             mes: "agosto",
             sessoes: 3,
             faltas: 1,
             recebimentos: 1,
             status: "open"
           } = Clinic.preview_month(@data, "agosto", @today)
  end

  test "preview_month/3 accepts YYYY-MM and ignores case and padding" do
    assert %{mes: "agosto", status: "open"} = Clinic.preview_month(@data, "2026-08", @today)
    assert %{mes: "agosto"} = Clinic.preview_month(@data, " Agosto ", @today)

    assert %{mes: "julho", status: "closed", sessoes: 1, recebimentos: 1} =
             Clinic.preview_month(@data, "julho", @today)
  end

  test "preview_month/3 returns nil for an unknown or mismatched month" do
    assert Clinic.preview_month(@data, "setembro", @today) == nil
    assert Clinic.preview_month(@data, "2025-08", @today) == nil
  end

  test "a relative month resolves against the date it was given" do
    # The tool schema advertises "este mês" as an example value and nothing resolved it —
    # both resumo_mensal and fechar_mes answered "mês desconhecido" to the phrase their
    # own description suggests. This test used to assert that nil, which is how a
    # description and its behaviour stay disagreed for a whole release.
    assert %{mes: "agosto"} = Clinic.preview_month(@data, "este mês", @today)
    assert %{mes: "agosto"} = Clinic.preview_month(@data, "esse mes", @today)
    assert %{mes: "julho"} = Clinic.preview_month(@data, "mês passado", @today)

    # December rolls the year back rather than asking for month zero.
    assert Clinic.preview_month(@data, "mês passado", ~D[2026-01-09]) == nil
  end

  test "every spelling of one month gives one answer" do
    # They used to give two. With a months registry saying agosto is 2025 and sessions
    # dated 2026-08, "agosto" returned a confident sessoes: 0 while "2026-08" returned
    # nil — two spellings, two stories, and the confident one was the wrong one.
    data = %{
      "patients" => [],
      "sessions" => [%{"patient_id" => "p1", "date" => "2026-08-15", "status" => "compareceu"}],
      "receipts" => [],
      "months" => %{"agosto" => %{"status" => "open", "year" => 2025}}
    }

    by_name = Clinic.preview_month(data, "agosto", @today)
    by_iso = Clinic.preview_month(data, "2025-08", @today)
    other_year = Clinic.preview_month(data, "2026-08", @today)

    assert by_name == by_iso, "the two spellings of 2025-08 disagree"
    assert other_year == nil, "2026-08 is not in the registry and must not resolve"
  end

  test "close_month/3 returns a new snapshot with the month closed" do
    assert {:ok, closed} = Clinic.close_month(@data, "agosto", @today)
    assert closed["months"]["agosto"]["status"] == "closed"
    assert @data["months"]["agosto"]["status"] == "open"
    assert {:error, :already_closed} = Clinic.close_month(closed, "agosto", @today)
    assert {:error, :already_closed} = Clinic.close_month(@data, "julho", @today)
    assert {:error, :unknown_month} = Clinic.close_month(@data, "setembro", @today)
  end

  test "close_month/3 via YYYY-MM updates the named key" do
    assert {:ok, closed} = Clinic.close_month(@data, "2026-08", @today)
    assert closed["months"]["agosto"]["status"] == "closed"
  end

  test "a row the JSON did not have to be well formed about is skipped, not fatal" do
    # month_rows/4 has a defensive clause for this and nothing exercised it, so the
    # clause could have been deleted by anyone tidying up and no test would have noticed.
    # The snapshot is a JSON file a human edits.
    ragged =
      @data
      |> Map.update!(
        "sessions",
        &(&1 ++ [%{"patient_id" => "p9"}, %{"date" => 20_260_801}, "junk"])
      )
      |> Map.update!("receipts", &(&1 ++ [%{"valor" => "50"}]))

    assert %{mes: "agosto", sessoes: 3, recebimentos: 1} =
             Clinic.preview_month(ragged, "agosto", @today)

    assert length(Clinic.sessions_on(ragged, ~D[2026-08-15])) == 2
  end

  test "the ISO spelling reaches the same errors the name spelling does" do
    # close_month/3's ISO path was only tested on the success case, so the two error
    # returns were reachable by one spelling and untested by the other.
    {:ok, closed} = Clinic.close_month(@data, "2026-08", @today)

    assert {:error, :already_closed} = Clinic.close_month(closed, "2026-08", @today)
    assert {:error, :already_closed} = Clinic.close_month(@data, "2026-07", @today)
    assert {:error, :unknown_month} = Clinic.close_month(@data, "2026-09", @today)
    assert {:error, :unknown_month} = Clinic.close_month(@data, "2026-13", @today)
  end

  test "a two-digit month is not zero-padded into a prefix that matches nothing" do
    # month_prefix/2 has a clause each side of ten and only the padded one was reached, so
    # October through December were untested — and a wrong prefix there would report a
    # confident zero rather than an error.
    data = %{
      "patients" => [],
      "sessions" => [
        %{"patient_id" => "p1", "date" => "2026-11-03", "status" => "compareceu"},
        %{"patient_id" => "p1", "date" => "2026-01-03", "status" => "compareceu"}
      ],
      "receipts" => [%{"patient_id" => "p1", "date" => "2026-11-03", "valor" => "250"}],
      "months" => %{"novembro" => %{"status" => "open", "year" => 2026}}
    }

    assert %{mes: "novembro", sessoes: 1, recebimentos: 1} =
             Clinic.preview_month(data, "novembro", @today)

    assert %{mes: "novembro"} = Clinic.preview_month(data, "2026-11", @today)
  end
end
