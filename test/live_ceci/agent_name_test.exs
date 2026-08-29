defmodule LiveCeci.AgentNameTest do
  @moduledoc """
  The agent is called Ceci, and this is the file that says so.

  The name is not decoration. It appears in four places that each fail differently,
  and a rename that misses one of them compiles clean and passes every other test in
  this suite:

    * the system instruction, where it tells the model who to be
    * the `:ceci` atom the providers tag her transcripts with
    * the `"ceci"` string that atom becomes on the wire
    * the browser, which colours her lines by a CSS class of the same name

  The last one is the reason for `no lingering "mira"` below. A missed rename in
  `priv/frontend` is invisible to the compiler and to every unit test: the server
  would send `role: "ceci"`, the stylesheet would still be matching `.line.mira`, and
  the only symptom is her transcript quietly losing its colour.
  """
  use ExUnit.Case, async: true

  alias LiveCeci.{Persona, Socket}

  @name "Ceci"

  describe "the agent is named Ceci" do
    test "the system instruction tells the model who she is" do
      assert Persona.instruction() =~ "Você é a #{@name}, assistente operacional"
    end

    test "the Content struct carries the same name — it is the one the API reads" do
      assert %{parts: [%{text: text}]} = Persona.system_instruction()
      assert text =~ "Você é a #{@name},"
    end

    test "her transcripts reach the browser tagged \"ceci\"" do
      # The atom -> string hop. Providers emit :ceci; this is where it becomes the
      # role the frontend switches on.
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, {:transcript, :ceci, "oi"}}, %{
                 session: self(),
                 provider: LiveCeci.Provider.Grok
               })

      assert %{"role" => "ceci"} = Jason.decode!(json)
    end
  end

  describe "no lingering \"mira\"" do
    # Scoped to the code that runs, not to docs or tests: those may legitimately
    # discuss the rename, and a guard that forbids naming the old name would forbid
    # explaining it.
    @roots ["lib", "priv/frontend", "priv/assets/ceci_persona.txt"]

    # Anchored to the forms the name actually took, not the bare substring. `~r/mira/i`
    # matched "admirar" and "mirante" too, so the guard would have fired on ordinary
    # Portuguese the day any of this code grew a comment containing one.
    @old_name ~r/(:mira\b|"mira"|\.mira\b|\bMira\b|mira_persona)/

    test "the shipped code and the browser client never say the old name" do
      offenders =
        @roots
        |> Enum.flat_map(&paths/1)
        |> Enum.filter(fn path ->
          case File.read(path) do
            {:ok, contents} -> contents =~ @old_name
            {:error, _} -> false
          end
        end)

      assert offenders == [],
             "the rename to Ceci missed: #{Enum.join(offenders, ", ")}"
    end

    test "the persona file is the one Ceci is named after" do
      # A stale mira_persona.txt left beside the new one would be dead weight that
      # still reads like the source of truth.
      assets = Path.join(:code.priv_dir(:live_ceci), "assets")

      assert File.exists?(Path.join(assets, "ceci_persona.txt"))
      refute File.exists?(Path.join(assets, "mira_persona.txt"))
    end
  end

  defp paths(root) do
    cond do
      File.regular?(root) ->
        [root]

      File.dir?(root) ->
        root |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

      true ->
        []
    end
  end
end
