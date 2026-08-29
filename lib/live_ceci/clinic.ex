defmodule LiveCeci.Clinic do
  @moduledoc """
  Pure queries over a clinic snapshot map.

  No process, no clock, no ETS. Pass `data` and a `Date` in. Tests use map
  literals with `async: true`. JSON keys stay strings — never `String.to_atom/1`.
  """

  @months ~w(janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)

  @spec patients(map()) :: [map()]
  def patients(data) when is_map(data), do: Map.get(data, "patients", [])

  @spec sessions_on(map(), Date.t()) :: [map()]
  def sessions_on(data, %Date{} = date) when is_map(data) do
    iso = Date.to_iso8601(date)

    data
    |> Map.get("sessions", [])
    |> Enum.filter(&match?(%{"date" => ^iso}, &1))
  end

  @spec preview_month(map(), String.t()) :: map() | nil
  def preview_month(data, mes) when is_map(data) and is_binary(mes) do
    case resolve_month(data, mes) do
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

  @spec close_month(map(), String.t()) ::
          {:ok, map()} | {:error, :unknown_month | :already_closed}
  def close_month(data, mes) when is_map(data) and is_binary(mes) do
    case resolve_month(data, mes) do
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

  defp resolve_month(data, mes) do
    months = Map.get(data, "months", %{})
    needle = mes |> String.trim() |> String.downcase()

    cond do
      is_map(Map.get(months, needle)) ->
        meta = Map.fetch!(months, needle)

        case year_month(needle, meta) do
          {year, month} -> {needle, meta, {year, month}}
          nil -> nil
        end

      true ->
        case iso_year_month(needle) do
          {year, month} ->
            name = Enum.at(@months, month - 1)

            case Map.get(months, name) do
              %{"year" => ^year} = meta -> {name, meta, {year, month}}
              _ -> nil
            end

          nil ->
            nil
        end
    end
  end

  defp year_month(key, meta) do
    case iso_year_month(key) do
      {year, month} ->
        {year, month}

      nil ->
        year = meta["year"]
        month = month_number(key)
        if is_integer(year) and is_integer(month), do: {year, month}
    end
  end

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
