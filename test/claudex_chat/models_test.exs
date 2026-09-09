defmodule ClaudexChat.ModelsTest do
  use ExUnit.Case, async: true

  alias Claudex.Model, as: APIModel
  alias ClaudexChat.Models
  alias ClaudexChat.Models.{Capabilities, Model}

  defp decoded(fixture) do
    Path.expand("../fixtures/#{fixture}", __DIR__)
    |> File.read!()
    |> JSON.decode!()
  end

  describe "Capabilities.to_entry/1 on a recorded Models API response" do
    test "reads Haiku 4.5 as taking a thinking budget, not adaptive" do
      entry = "model.json" |> decoded() |> APIModel.decode() |> Capabilities.to_entry()

      assert entry.id == "claude-haiku-4-5-20251001"
      assert entry.display_name == "Claude Haiku 4.5"
      assert entry.max_output_tokens == 64_000
      assert entry.thinking_modes == ~w(off enabled)
      assert entry.accepts_images
      assert entry.accepts_pdf
    end

    test "reads Fable 5.1 as adaptive-only" do
      entry =
        "models_page.json"
        |> decoded()
        |> Map.fetch!("data")
        |> hd()
        |> APIModel.decode()
        |> Capabilities.to_entry()

      assert entry.id == "claude-fable-5-1"
      assert entry.thinking_modes == ~w(off adaptive)
    end

    test "treats a model with no capabilities as thinking-free" do
      entry = Capabilities.to_entry(%APIModel{id: "mystery", display_name: nil, max_tokens: nil})

      assert entry.display_name == "mystery"
      assert entry.thinking_modes == ["off"]
      refute entry.accepts_images
      refute entry.accepts_pdf
    end
  end

  describe "fallback/0" do
    test "every entry is usable without the API" do
      for %Model{} = model <- Models.fallback() do
        assert model.id != ""
        assert model.max_output_tokens > 0
        assert "off" in model.thinking_modes
        assert Enum.all?(model.thinking_modes, &(&1 in ~w(off adaptive enabled)))
      end
    end
  end

  describe "accepted_types/1" do
    test "narrows to what the model takes" do
      text_only = %Model{
        id: "t",
        display_name: "T",
        max_output_tokens: 1000,
        thinking_modes: ["off"]
      }

      refute Enum.any?(Model.accepted_types(text_only), &String.starts_with?(&1, "image/"))
      assert "text/plain" in Model.accepted_types(text_only)
    end
  end
end
