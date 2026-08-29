defmodule LiveCeci.Clinic do
  @moduledoc """
  Pure queries over a clinic snapshot map.

  No process, no clock, no ETS. Pass `data` and a `Date` in — including for a relative
  month like "este mês", which is why `preview_month/3` and `close_month/3` take today
  rather than reaching for `LiveCeci.Clock`. Tests use map literals with `async: true`.
  JSON keys stay strings — never `String.to_atom/1`.

  ## One month, one answer

  Month resolution used to have two independent paths, and they could disagree about the
  same real month: with a `months` registry saying agosto is 2025 and sessions dated
  2026-08, `"agosto"` answered a confident `sessoes: 0` while `"2026-08"` answered `nil`.
  Two spellings, two stories, and the confident one was the wrong one.

  `resolve_month/3` now derives a single `{year, month}` first — from a relative phrase,
  an ISO `YYYY-MM`, or a bare name plus the year the registry stores for it — and only
  then looks up the registry entry for that pair. Every spelling of the same month lands
  on the same answer, or on `nil` together.
  """

  @months ~w(janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)

  # What a person actually says out loud, with and without the accent, because a
  # transcript is not spelled by a copy editor. The tool schema advertises "este mês" as
  # an example value and nothing resolved it — reproduced, both `resumo_mensal` and
  # `fechar_mes` answered "mês desconhecido" to the phrase their own description suggests.
  @this_month ["este mês", "este mes", "esse mês", "esse mes", "mês atual", "mes atual"]
  @last_month ["mês passado", "mes passado", "último mês", "ultimo mes", "mes passado"]

  @spec patients(map()) :: [map()]
  def patients(data) when is_map(data), do: Map.get(data, "patients", [])

  @spec sessions_on(map(), Date.t()) :: [map()]
  def sessions_on(data, %Date{} = date) when is_map(data) do
    iso = Date.to_iso8601(date)

    data
    |> Map.get("sessions", [])
    |> Enum.filter(&match?(%{"date" => ^iso}, &1))
  end

  @spec preview_month(map(), String.t(), Date.t()) :: map() | nil
  def preview_month(data, mes, %Date{} = today) when is_map(data) and is_binary(mes) do
    case resolve_month(data, mes, today) do
      {key, meta, {year, month}} ->
        sessions = month_rows(data, "sessions", year, month)
        receipts = month_rows(data, "receipts", year, month)

        %{
          mes: key,
          sessoes: length(sessions),
          faltas: Enum.count(sessions, &(&1["status"] == "faltou")),
          recebimentos: length(receipts),
          status: meta["status"]
        }

      nil ->
        nil
    end
  end

  @spec close_month(map(), String.t(), Date.t()) ::
          {:ok, map()} | {:error, :unknown_month | :already_closed}
  def close_month(data, mes, %Date{} = today) when is_map(data) and is_binary(mes) do
    case resolve_month(data, mes, today) do
      {_key, %{"status" => "closed"}, _ym} ->
        {:error, :already_closed}

      {key, meta, _ym} ->
        months =
          data
          |> Map.get("months", %{})
          |> Map.put(key, Map.put(meta, "status", "closed"))

        {:ok, Map.put(data, "months", months)}

      nil ->
        {:error, :unknown_month}
    end
  end

  defp resolve_month(data, mes, today) do
    months = Map.get(data, "months", %{})
    needle = mes |> String.trim() |> String.downcase()

    # Derive the {year, month} FIRST, from whichever spelling arrived, then find the one
    # registry entry that names it. Two paths deriving two different pairs is what let the
    # spellings disagree.
    with {year, month} <- year_month(needle, months, today),
         name when is_binary(name) <- Enum.at(@months, month - 1),
         %{"year" => ^year} = meta <- Map.get(months, name) do
      {name, meta, {year, month}}
    else
      _ -> nil
    end
  end

  defp year_month(needle, months, today) do
    cond do
      needle in @this_month -> {today.year, today.month}
      needle in @last_month -> previous_month(today)
      true -> iso_year_month(needle) || named_year_month(needle, months)
    end
  end

  # A bare month name carries no year, so the registry is the only place one can come
  # from. If the registry does not know the name, neither do we.
  defp named_year_month(needle, months) do
    with month when is_integer(month) <- month_number(needle),
         %{"year" => year} when is_integer(year) <- Map.get(months, needle) do
      {year, month}
    else
      _ -> nil
    end
  end

  defp previous_month(%Date{year: year, month: 1}), do: {year - 1, 12}
  defp previous_month(%Date{year: year, month: month}), do: {year, month - 1}

  defp iso_year_month(<<y::binary-size(4), "-", m::binary-size(2)>>) do
    case Date.from_iso8601(y <> "-" <> m <> "-01") do
      {:ok, %Date{year: year, month: month}} -> {year, month}
      _ -> nil
    end
  end

  defp iso_year_month(_), do: nil

  defp month_number(name) do
    case Enum.find_index(@months, &(&1 == name)) do
      nil -> nil
      index -> index + 1
    end
  end

  defp month_rows(data, key, year, month) do
    prefix = month_prefix(year, month)

    data
    |> Map.get(key, [])
    |> Enum.filter(fn
      %{"date" => date} when is_binary(date) -> String.starts_with?(date, prefix)
      _other -> false
    end)
  end

  defp month_prefix(year, month) when month < 10, do: "#{year}-0#{month}"
  defp month_prefix(year, month), do: "#{year}-#{month}"
end
