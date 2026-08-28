defmodule LiveDJ.PersonaTest do
  use ExUnit.Case, async: true

  alias LiveDJ.Persona

  test "loads a non-empty instruction" do
    instruction = Persona.instruction()
    assert is_binary(instruction)
    assert String.length(instruction) > 200
  end

  test "carries both halves: who Mira is, and that she is now live" do
    instruction = Persona.instruction()
    assert instruction =~ "You are Mira, a late-night radio DJ."
    assert instruction =~ "You are now LIVE"
  end

  test "names every tool the model is allowed to call" do
    instruction = Persona.instruction()
    for %{name: name} <- LiveDJ.Tools.declarations(), do: assert(instruction =~ name)
  end

  test "system_instruction/0 is shaped as the Content the setup message expects" do
    assert %{parts: [%{text: text}]} = Persona.system_instruction()
    assert text == Persona.instruction()
  end
end
