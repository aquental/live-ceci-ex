defmodule LiveCeci.ClinicTest do
  use ExUnit.Case, async: true

  alias LiveCeci.Clinic

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

  test "preview_month/2 counts sessions, faltas and receipts for a named month" do
    assert %{
             mes: "agosto",
             sessoes: 3,
             faltas: 1,
             recebimentos: 1,
             status: "open"
           } = Clinic.preview_month(@data, "agosto")
  end

  test "preview_month/2 accepts YYYY-MM and ignores case and padding" do
    assert %{mes: "agosto", status: "open"} = Clinic.preview_month(@data, "2026-08")
    assert %{mes: "agosto"} = Clinic.preview_month(@data, " Agosto ")

    assert %{mes: "julho", status: "closed", sessoes: 1, recebimentos: 1} =
             Clinic.preview_month(@data, "julho")
  end

  test "preview_month/2 returns nil for an unknown or mismatched month" do
    assert Clinic.preview_month(@data, "setembro") == nil
    assert Clinic.preview_month(@data, "2025-08") == nil
    assert Clinic.preview_month(@data, "este mês") == nil
  end

  test "close_month/2 returns a new snapshot with the month closed" do
    assert {:ok, closed} = Clinic.close_month(@data, "agosto")
    assert closed["months"]["agosto"]["status"] == "closed"
    assert @data["months"]["agosto"]["status"] == "open"
    assert {:error, :already_closed} = Clinic.close_month(closed, "agosto")
    assert {:error, :already_closed} = Clinic.close_month(@data, "julho")
    assert {:error, :unknown_month} = Clinic.close_month(@data, "setembro")
  end

  test "close_month/2 via YYYY-MM updates the named key" do
    assert {:ok, closed} = Clinic.close_month(@data, "2026-08")
    assert closed["months"]["agosto"]["status"] == "closed"
  end
end
