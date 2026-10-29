defmodule ClaudexChatWeb.ChatLive do
  @moduledoc """
  The chat page: history on the left, the conversation in the middle, the
  composer underneath.

  The conversation runs in `Claudex.ToolRunner.stream_to/3`, which posts each
  event and each finished turn to this process. Every one of those messages is
  matched against the handle's `ref`, so a run from a chat the user has since
  left can't write into the one on screen.

  A run halts on a tool call nobody has decided on. Approving or denying the
  last pending call starts the next run, which picks the conversation up from
  the stored history.
  """

  use ClaudexChatWeb, :live_view

  import ClaudexChatWeb.ChatLive.Components

  alias ClaudexChat.{Approvals, Attachments, Chats, Claude, Completions, Models}
  alias ClaudexChat.Chats.Message
  alias ClaudexChat.Completions.Reply
  alias ClaudexChat.Models.Model

  @accept ~w(.png .jpg .jpeg .gif .webp .pdf .txt .md)
  @max_file_size 20_000_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    model = Models.default()

    {:ok,
     socket
     |> assign(
       page_title: "Chat",
       model_groups: Models.grouped(),
       model: model,
       thinking_mode: "off",
       catalogue_source: Models.source(),
       api_configured?: Claude.configured?(),
       chat: nil,
       reply: nil,
       handle: nil,
       awaiting_message: nil,
       content: "",
       mcp_servers: [],
       mcp_menu_open: false
     )
     |> stream(:chats, Chats.list_chats())
     |> stream(:messages, [])
     |> allow_upload(:attachments,
       accept: @accept,
       max_entries: 4,
       max_file_size: @max_file_size
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chats.fetch_chat(id) do
      {:ok, chat} -> {:noreply, open_chat(socket, chat)}
      {:error, :not_found} -> {:noreply, push_patch(socket, to: ~p"/")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, close_chat(socket)}

  @impl Phoenix.LiveView
  # The composer form needs a phx-change binding for uploads to report their
  # progress; nothing here is validated. The textarea is debounced to "blur"
  # so a prompt isn't re-sent to the server on every keystroke.
  def handle_event("composer_change", params, socket) do
    {:noreply, preserve_content(socket, params["content"])}
  end

  def handle_event("drop_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("set_model", %{"model" => id}, socket) do
    case Models.fetch(id) do
      {:ok, model} ->
        {:noreply,
         apply_settings(socket, model, supported_mode(model, socket.assigns.thinking_mode))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("set_thinking", %{"thinking" => mode}, socket) do
    {:noreply, apply_settings(socket, socket.assigns.model, mode)}
  end

  def handle_event("toggle_mcp_menu", _params, socket) do
    {:noreply, update(socket, :mcp_menu_open, &(!&1))}
  end

  def handle_event("toggle_mcp", %{"name" => name}, socket) do
    servers = toggle_membership(socket.assigns.mcp_servers, name)

    {:noreply, socket |> apply_mcp_servers(servers) |> assign(:mcp_menu_open, false)}
  end

  def handle_event("send", %{"content" => content}, socket) do
    if String.trim(content) == "" do
      {:noreply, socket}
    else
      {:noreply, send_prompt(socket, content)}
    end
  end

  def handle_event("approve_tool", %{"id" => call_id}, socket) do
    {:noreply, decide(socket, &Approvals.approve(&1, call_id))}
  end

  def handle_event("deny_tool", %{"id" => call_id}, socket) do
    {:noreply, decide(socket, &Approvals.deny(&1, call_id))}
  end

  def handle_event(
        "replay",
        %{"id" => id},
        %{assigns: %{handle: nil, awaiting_message: nil}} = socket
      ) do
    chat = socket.assigns.chat

    with {:ok, original} <- Chats.fetch_message(id),
         true <- chat && original.chat_id == chat.id,
         {:ok, %{message: message, chat: chat}} <- Chats.replay_user_message(chat, original) do
      {:noreply,
       socket
       |> assign(chat: chat)
       |> stream_insert(:messages, message)
       |> stream_insert(:chats, chat, at: 0)
       |> start_run(chat, &Completions.start/1)}
    else
      _not_replayable -> {:noreply, socket}
    end
  end

  def handle_event("replay", _params, socket), do: {:noreply, socket}

  def handle_event("retry", %{"id" => id}, socket) do
    with {:ok, message} <- Chats.fetch_message(id),
         %{id: chat_id} <- socket.assigns.chat,
         true <- message.chat_id == chat_id,
         {:ok, discarded} <- Chats.discard_from(message) do
      chat = socket.assigns.chat

      # Only the discarded messages leave the page. Resetting the whole list
      # would empty the conversation for a moment, and the browser would
      # scroll it back to the top.
      {:noreply,
       socket
       |> assign(awaiting_message: nil, reply: nil)
       |> then(
         &Enum.reduce(discarded, &1, fn gone, socket -> stream_delete(socket, :messages, gone) end)
       )
       |> start_run(chat, &Completions.start/1)}
    else
      _not_retryable -> {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.handle, do: Completions.cancel(socket.assigns.handle)

    {:noreply, socket}
  end

  def handle_event("delete_chat", %{"id" => id}, socket) do
    {:ok, chat} = Chats.fetch_chat(id)
    {:ok, _chat} = Chats.delete_chat(chat)

    socket = stream_delete(socket, :chats, chat)

    if socket.assigns.chat && socket.assigns.chat.id == chat.id do
      {:noreply, push_patch(socket, to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:claudex, ref, {:events, events}}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, update(socket, :reply, &Reply.add_events(&1, events))}
  end

  def handle_info({:claudex, ref, {:turn, turn}}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, record_turn(socket, turn)}
  end

  def handle_info({:claudex, ref, :done}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, assign(socket, handle: nil, reply: nil)}
  end

  # The turn a cancel ended has already arrived and been stored.
  def handle_info({:claudex, ref, :cancelled}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, socket |> assign(handle: nil, reply: nil) |> reopen_awaiting()}
  end

  def handle_info({:claudex, ref, {:error, error}}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    reply = Reply.failed(socket.assigns.reply, Completions.describe(error))

    {:noreply, record_failure(socket, reply)}
  end

  def handle_info({:claudex, _stale_ref, _message}, socket), do: {:noreply, socket}

  defp open_chat(socket, chat) do
    model = model_or_default(chat.model)
    messages = Chats.list_messages(chat)

    socket
    |> cancel_run()
    |> assign(
      chat: chat,
      model: model,
      thinking_mode: chat.thinking_mode,
      mcp_servers: chat.mcp_servers,
      mcp_menu_open: false,
      page_title: chat.title
    )
    |> assign(awaiting_message: awaiting_message(messages), reply: nil, handle: nil)
    |> stream(:messages, Chats.list_messages(chat), reset: true)
    |> stream(:chats, Chats.list_chats(), reset: true)
  end

  defp close_chat(socket) do
    socket
    |> cancel_run()
    |> assign(chat: nil, reply: nil, handle: nil, awaiting_message: nil, page_title: "Chat")
    |> stream(:messages, [], reset: true)
    |> stream(:chats, Chats.list_chats(), reset: true)
  end

  # Leaving a chat stops its run: nobody is left to read the reply, and a
  # resumed run would otherwise go on running tools.
  defp cancel_run(%{assigns: %{handle: nil}} = socket), do: socket

  defp cancel_run(%{assigns: %{handle: handle}} = socket) do
    Completions.cancel(handle)
    socket
  end

  defp apply_settings(socket, model, mode) do
    socket = assign(socket, model: model, thinking_mode: mode)

    case socket.assigns.chat do
      nil ->
        socket

      chat ->
        {:ok, chat} =
          Chats.update_chat(chat, settings_attrs(model, mode, socket.assigns.mcp_servers))

        socket |> assign(:chat, chat) |> stream_insert(:chats, chat)
    end
  end

  # Membership only, not the menu — a chat can be closed and reopened, but
  # what it's enabled stays whatever it was.
  defp apply_mcp_servers(socket, servers) do
    socket = assign(socket, :mcp_servers, servers)

    case socket.assigns.chat do
      nil ->
        socket

      chat ->
        {:ok, chat} =
          Chats.update_chat(
            chat,
            settings_attrs(socket.assigns.model, socket.assigns.thinking_mode, servers)
          )

        socket |> assign(:chat, chat) |> stream_insert(:chats, chat)
    end
  end

  defp toggle_membership(names, name) do
    if name in names, do: List.delete(names, name), else: [name | names]
  end

  defp settings_attrs(model, mode, mcp_servers) do
    %{
      model: model.id,
      thinking_mode: mode,
      thinking_budget: thinking_budget(mode),
      mcp_servers: mcp_servers
    }
  end

  defp supported_mode(model, mode) do
    if Model.supports_thinking?(model, mode), do: mode, else: "off"
  end

  defp thinking_budget("enabled"), do: 4096
  defp thinking_budget(_mode), do: nil

  defp send_prompt(socket, content) do
    {:ok, chat} = ensure_chat(socket)
    attachments = consume_attachments(socket)

    {:ok, %{message: message, chat: chat}} =
      Chats.add_user_message(chat, %{content: content, attachments: attachments})

    socket
    |> assign(chat: chat)
    |> assign(content: "")
    |> stream_insert(:messages, message)
    |> stream_insert(:chats, chat, at: 0)
    |> push_event("chat:sent", %{})
    |> start_run(chat, &Completions.start/1)
  end

  defp ensure_chat(%{assigns: %{chat: nil}} = socket) do
    Chats.create_chat(
      settings_attrs(
        socket.assigns.model,
        socket.assigns.thinking_mode,
        socket.assigns.mcp_servers
      )
    )
  end

  defp ensure_chat(%{assigns: %{chat: chat}}), do: {:ok, chat}

  defp start_run(socket, chat, run) do
    case run.(chat) do
      {:ok, handle} ->
        assign(socket, handle: handle, reply: Reply.new(chat.model))

      {:error, reason} ->
        reply = Reply.failed(Reply.new(chat.model), Completions.describe(reason))

        record_failure(socket, reply)
    end
  end

  # A turn that halted for approval leaves its reply waiting on a human. The
  # next turn's events start a reply of their own.
  defp record_turn(socket, turn) do
    %{chat: chat, reply: reply, awaiting_message: awaiting} = socket.assigns

    case Completions.record_turn(chat, reply, awaiting, turn) do
      {:ok, %{message: message, chat: chat}} ->
        socket
        |> assign(chat: chat, reply: Reply.new(chat.model))
        |> assign(:awaiting_message, if(Approvals.awaiting?(message), do: message))
        |> stream_insert(:messages, message)
        |> warn_on_stop(turn.stop)

      {:error, _changeset} ->
        put_flash(socket, :error, "The reply couldn't be saved.")
    end
  end

  defp warn_on_stop(socket, :max_turns),
    do: put_flash(socket, :error, "Claude kept going for ten requests in a row; stopped there.")

  defp warn_on_stop(socket, _stop), do: socket

  # A request that failed keeps whatever arrived, and a resumed run that
  # failed hands its calls back to the human to decide again.
  defp record_failure(socket, reply) do
    socket = assign(socket, handle: nil, reply: nil)

    socket =
      case Completions.record_failure(socket.assigns.chat, reply) do
        {:ok, %{message: message, chat: chat}} ->
          socket |> assign(:chat, chat) |> stream_insert(:messages, message)

        _ignored_or_failed ->
          socket
      end

    reopen_awaiting(socket)
  end

  defp reopen_awaiting(%{assigns: %{awaiting_message: nil}} = socket), do: socket

  defp reopen_awaiting(%{assigns: %{awaiting_message: message}} = socket) do
    {:ok, message} = Approvals.reopen(message)

    socket
    |> assign(:awaiting_message, message)
    |> stream_insert(:messages, message)
  end

  # Deciding the last pending call in a reply is what lets the conversation
  # go on, so the run resumes as soon as none are left.
  defp decide(socket, decision) do
    with %Message{} = awaiting <- socket.assigns.awaiting_message,
         nil <- socket.assigns.handle,
         {:ok, message} <- decision.(awaiting) do
      socket = socket |> assign(:awaiting_message, message) |> stream_insert(:messages, message)

      if Approvals.awaiting?(message),
        do: socket,
        else: start_run(socket, socket.assigns.chat, &Completions.resume(&1, message))
    else
      _nothing_to_decide -> socket
    end
  end

  defp awaiting_message(messages) do
    with %Message{} = message <- List.last(messages),
         {:ok, message} <- Approvals.reopen(message) do
      if Approvals.awaiting?(message), do: message
    else
      _none -> nil
    end
  end

  defp consume_attachments(socket) do
    consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
      case Attachments.upload(path, entry.client_name, entry.client_type) do
        {:ok, attrs} -> {:ok, attrs}
        {:error, _reason} -> {:ok, nil}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp model_or_default(id) do
    case Models.fetch(id) do
      {:ok, model} -> model
      {:error, :not_found} -> Models.default()
    end
  end

  defp preserve_content(socket, nil), do: socket

  defp preserve_content(socket, content) do
    socket
    |> assign(:content, content)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <aside class="flex w-64 shrink-0 flex-col border-r border-base-300 bg-base-200">
        <div class="flex items-center justify-between px-3 py-3">
          <span class="flex items-center gap-2 px-1 font-mono text-sm font-semibold tracking-tight">
            <.logo /> claudex·chat
          </span>
          <Layouts.theme_toggle />
        </div>

        <div class="px-3 pb-2">
          <.link
            patch={~p"/"}
            id="new-chat"
            class="flex items-center justify-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium hover:bg-base-100/60"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New chat
          </.link>
        </div>

        <nav id="chats" phx-update="stream" class="flex-1 space-y-0.5 overflow-y-auto px-3 pb-3">
          <div id="no-chats" class="hidden px-3 py-2 text-sm text-base-content/40 only:block">
            No chats yet
          </div>
          <.chat_row
            :for={{dom_id, chat} <- @streams.chats}
            id={dom_id}
            chat={chat}
            current_id={@chat && @chat.id}
          />
        </nav>

        <div class="border-t border-base-300 px-4 py-2 font-mono text-[11px] text-base-content/40">
          models: {@catalogue_source}
        </div>
      </aside>

      <main class="flex min-w-0 flex-1 flex-col bg-base-100">
        <div
          :if={!@api_configured?}
          class="border-b border-warning/30 bg-warning/10 px-4 py-2 text-center text-xs"
        >
          No <code class="font-mono">ANTHROPIC_API_KEY</code>
          is configured, so replies can't be requested.
        </div>

        <div id="conversation" phx-hook=".ScrollToBottom" class="flex-1 overflow-y-auto px-4 py-6">
          <div class="mx-auto max-w-3xl space-y-6">
            <div id="messages" phx-update="stream" class="space-y-6">
              <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
                <.message message={message} />
              </div>
            </div>

            <.streaming_reply :if={@reply} reply={@reply} />

            <div :if={is_nil(@chat)} class="pt-24 text-center">
              <h1 class="text-2xl font-semibold tracking-tight">What can I help with?</h1>
              <p class="mt-2 text-sm text-base-content/50">
                Streaming through the Claudex SDK, on {@model.display_name}.
              </p>
            </div>
          </div>
        </div>

        <.composer
          model_groups={@model_groups}
          model={@model}
          thinking_mode={@thinking_mode}
          uploads={@uploads}
          streaming={!is_nil(@handle)}
          disabled={!@api_configured? or not is_nil(@awaiting_message)}
          content={@content}
          mcp_servers={@mcp_servers}
          mcp_menu_open={@mcp_menu_open}
        />
      </main>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() {
            this.pin()
            this.observer = new MutationObserver(() => this.pin())
            this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
          },
          destroyed() {
            this.observer && this.observer.disconnect()
          },
          pin() {
            const slack = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
            if (slack < 200) { this.el.scrollTop = this.el.scrollHeight }
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
