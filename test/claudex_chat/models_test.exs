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

  describe "rank/1 and lifecycle_note/1" do
    defp entry(id, line, created_at, attrs \\ %{}) do
      struct!(
        %Model{id: id, display_name: id, max_output_tokens: 1000, thinking_modes: ["off"]},
        Map.merge(%{line: line, created_at: created_at}, attrs)
      )
    end

    test "orders by line, then the most recently released first" do
      models = [
        entry("claude-haiku-4-5", "haiku", ~U[2025-10-01 00:00:00Z]),
        entry("claude-opus-4-8", "opus", ~U[2026-05-01 00:00:00Z]),
        entry("claude-opus-5-5", "opus", ~U[2026-09-21 00:00:00Z]),
        entry("claude-fable-5-1", "fable", ~U[2026-08-01 00:00:00Z])
      ]

      assert models |> Enum.sort_by(&Model.rank/1) |> Enum.map(& &1.id) ==
               ~w(claude-fable-5-1 claude-opus-5-5 claude-opus-4-8 claude-haiku-4-5)
    end

    test "says when a deprecated model retires, and nothing for an active one" do
      deprecated =
        entry("old", "opus", nil, %{lifecycle: "deprecated", retires_at: ~U[2027-01-15 00:00:00Z]})

      assert Model.lifecycle_note(deprecated) == "retires 2027-01-15"
      assert Model.lifecycle_note(%{deprecated | retires_at: nil}) == "deprecated"
      assert Model.lifecycle_note(entry("new", "opus", nil, %{lifecycle: "active"})) == nil
    end

    test "reads the line, release date and lifecycle off the Models API" do
      entry = "model.json" |> decoded() |> APIModel.decode() |> Capabilities.to_entry()

      assert entry.line == "haiku"
      assert %DateTime{} = entry.created_at
      assert Model.family_label(entry) == "Haiku"
    end
  end
end
