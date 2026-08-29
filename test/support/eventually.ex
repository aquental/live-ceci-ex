defmodule LiveCeci.Eventually do
  @moduledoc """
  Retries a condition until it holds or a budget runs out.

  Extracted because three test files had grown their own copy. Duplicated helpers drift:
  one of the three had a tighter budget than the `Task.async_stream` timeout on the same
  line, which turns a slow machine into a confusing failure rather than a slow pass.

  Exists at all because a fixed `Process.sleep` before an assertion is a claim about the
  machine rather than about the code — the shape of test that passes for a year and then
  fails once in CI.
  """

  @doc """
  Runs `check` until it returns true, or `budget_ms` elapses. Fast when it passes.
  """
  @spec eventually((-> boolean()), pos_integer()) :: boolean()
  def eventually(check, budget_ms \\ 2_000) do
    cond do
      check.() -> true
      budget_ms <= 0 -> false
      true -> Process.sleep(10) && eventually(check, budget_ms - 10)
    end
  end
end
