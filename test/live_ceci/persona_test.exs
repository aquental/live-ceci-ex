defmodule LiveCeci.PersonaTest do
  use ExUnit.Case, async: true

  alias LiveCeci.Persona

  test "loads a non-empty instruction" do
    instruction = Persona.instruction()
    assert is_binary(instruction)
    assert String.length(instruction) > 200
  end

  test "carries all three halves: who she is, what she will not touch, and that she is live" do
    instruction = Persona.instruction()
    assert instruction =~ "Você é a Ceci, assistente operacional"
    assert instruction =~ "só o operacional, nunca o clínico"
    assert instruction =~ "Você está AO VIVO"
  end

  test "the boundary is spelled out, not implied" do
    # The single most load-bearing sentence in the prompt: ceci.pro's whole promise is
    # that clinical content never reaches her. Softening this to a hint is a product
    # change, and it should have to break a test to happen.
    instruction = Persona.instruction()
    assert instruction =~ "não lê"
    assert instruction =~ "prontuário"
    assert instruction =~ "iniciais ou apelido"
  end

  test "names every tool the model is allowed to call" do
    instruction = Persona.instruction()
    for %{name: name} <- LiveCeci.Tools.declarations(), do: assert(instruction =~ name)
  end

  test "system_instruction/0 is shaped as the Content the setup message expects" do
    assert %{parts: [%{text: text}]} = Persona.system_instruction()
    assert text == Persona.instruction()
  end
end
