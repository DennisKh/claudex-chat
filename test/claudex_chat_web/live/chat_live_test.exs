defmodule ClaudexChatWeb.ChatLiveTest do
  @moduledoc """
  Mount and navigation only — nothing here reaches the Claude API.

  The mount assertions are not incidental: a child of a `phx-update="stream"`
  container without a DOM id crashes the LiveView on the first patch, and
  nothing but a real mount catches it.
  """

  use ClaudexChatWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudexChat.Chats

  defp chat(attrs \\ %{}) do
    {:ok, chat} = Chats.create_chat(Map.merge(%{model: "claude-opus-5"}, attrs))
    chat
  end

  test "mounts with no chats", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "What can I help with?"
    assert html =~ "No chats yet"
  end

  test "lists chats and opens one", %{conn: conn} do
    chat = chat()
    {:ok, %{message: _message}} = Chats.add_user_message(chat, %{content: "Explain GenServers"})

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Explain GenServers"

    html = view |> element("a[href='/chats/#{chat.id}']") |> render_click()

    assert html =~ "Explain GenServers"
    refute html =~ "What can I help with?"
  end

  test "redirects to the empty state when a chat is gone", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/chats/999999")
  end

  test "drops a thinking mode the newly chosen model doesn't support", %{conn: conn} do
    chat = chat(%{thinking_mode: "adaptive"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#model-select") |> render_change(%{"model" => "claude-haiku-4-5"})

    assert {:ok, reloaded} = Chats.fetch_chat(chat.id)
    assert reloaded.model == "claude-haiku-4-5"
    assert reloaded.thinking_mode == "off"
  end

  test "deletes a chat from the sidebar", %{conn: conn} do
    chat = chat()
    {:ok, _} = Chats.add_user_message(chat, %{content: "Throwaway"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#delete-chat-#{chat.id}") |> render_click()

    assert {:error, :not_found} = Chats.fetch_chat(chat.id)
    refute render(view) =~ "Throwaway"
  end
end
