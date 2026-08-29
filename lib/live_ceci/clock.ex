defmodule LiveCeci.Clock do
  @moduledoc """
  Calendar today, overridable in tests via `config :live_ceci, today: ~D[...]`.

  UTC date is the POC clock. America/São_Paulo vs UTC midnight is a known limit;
  this module does not load a timezone database.
  """

  @spec today() :: Date.t()
  def today, do: Application.get_env(:live_ceci, :today, Date.utc_today())
end
