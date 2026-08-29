defmodule LiveCeci.EnvSandbox do
  @moduledoc """
  `Application.put_env/3` that puts itself back, exactly.

  Five test files were moving `:live_ceci` config by hand, in two ad-hoc idioms, and both
  were wrong in a way that only showed up as a flake on some seeds:

    * `on_exit(fn -> Application.delete_env(:live_ceci, :max_sessions) end)` — but
      `config/runtime.exs` SETS that key at boot, in `:test` too. Deleting it does not
      restore it; it removes it, and the value silently becomes whatever default the
      reader passed. That is invisible while the two numbers agree, which they did.

    * `previous = Application.get_env(...)` … `Application.put_env(:live_ceci, key,
      previous)` — which, once a sibling test had deleted the key, saved `nil` and then
      *wrote `nil` back*. `LiveCeci.Limits.sessions_total/0` then answered `nil`, because
      `get_env/3`'s default only applies to an ABSENT key, not to one explicitly set to
      nil. That is what made `limits_test.exs` fail on one seed and pass on the next.

  The distinction that matters is absent versus present-and-nil, and `fetch_env/2` is the
  only one of the three that can tell them apart. So this is the only way tests move
  config now.
  """

  @doc """
  Sets `key` for the current test and restores its exact prior state afterwards —
  putting the old value back if there was one, deleting the key if there was not.
  """
  @spec put_env(atom(), term()) :: :ok
  def put_env(key, value) do
    restore =
      case Application.fetch_env(:live_ceci, key) do
        {:ok, previous} -> fn -> Application.put_env(:live_ceci, key, previous) end
        :error -> fn -> Application.delete_env(:live_ceci, key) end
      end

    ExUnit.Callbacks.on_exit(restore)
    Application.put_env(:live_ceci, key, value)
  end
end
