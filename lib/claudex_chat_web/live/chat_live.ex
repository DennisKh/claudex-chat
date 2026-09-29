defmodule ClaudexChatWeb.ChatLive do
  @moduledoc """
  The chat page: history on the left, the conversation in the middle, the
  composer underneath.

  A reply streams in through `Claudex.Messages.stream_to/3`, which posts events
  to this process. Every one of those messages is matched against the handle's
  `ref`, so a stream from a chat the user has since left can't write into the
  one on screen.
  """

  use ClaudexChatWeb, :live_view

  import ClaudexChatWeb.ChatLive.Components

  alias Claudex.Tracing

  alias ClaudexChat.{Approvals, Attachments, Chats, Claude, Completions, Models}
  alias ClaudexChat.Chats.Message
  alias ClaudexChat.Completions.Reply
  alias ClaudexChat.Models.Model

  @accept ~w(.png .jpg .jpeg .gif .webp .pdf .txt .md)
  @max_resumes 10
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
       resumes: 0,
       content: "",
       mcp_servers: [],
       mcp_menu_open: false,
       exchange_span: nil
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
       |> assign(chat: chat, resumes: 0)
       |> stream_insert(:messages, message)
       |> stream_insert(:chats, chat, at: 0)
       |> begin_exchange(chat)
       |> start_stream(chat)}
    else
      _not_replayable -> {:noreply, socket}
    end
  end

  def handle_event("replay", _params, socket), do: {:noreply, socket}

  def handle_event("retry", %{"id" => id}, socket) do
    with {:ok, message} <- Chats.fetch_message(id),
         %{id: chat_id} <- socket.assigns.chat,
         true <- message.chat_id == chat_id,
         {:ok, _count} <- Chats.discard_from(message) do
      chat = socket.assigns.chat

      {:noreply,
       socket
       |> assign(awaiting_message: nil, reply: nil, resumes: 0)
       |> stream(:messages, Chats.list_messages(chat), reset: true)
       |> begin_exchange(chat)
       |> start_stream(chat)}
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
  def handle_info({:claudex, ref, {:event, event}}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, assign(socket, :reply, Completions.apply_event(socket.assigns.reply, event))}
  end

  def handle_info({:claudex, ref, :done}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, store_reply(socket, socket.assigns.reply)}
  end

  def handle_info({:claudex, ref, :cancelled}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    {:noreply, store_reply(socket, Reply.cancelled(socket.assigns.reply))}
  end

  def handle_info({:claudex, ref, {:error, error}}, %{assigns: %{handle: %{ref: ref}}} = socket) do
    reply = Completions.fail(socket.assigns.reply, error)

    {:noreply, store_reply(socket, reply)}
  end

  def handle_info({:claudex, _stale_ref, _message}, socket), do: {:noreply, socket}

  defp open_chat(socket, chat) do
    model = model_or_default(chat.model)
    messages = Chats.list_messages(chat)

    socket
    |> discard_exchange()
    |> assign(
      chat: chat,
      model: model,
      thinking_mode: chat.thinking_mode,
      mcp_servers: chat.mcp_servers,
      mcp_menu_open: false,
      page_title: chat.title
    )
    |> assign(awaiting_message: awaiting_message(messages), reply: nil, handle: nil)
    |> stream(:messages, messages, reset: true)
    |> stream(:chats, Chats.list_chats(), reset: true)
  end

  defp close_chat(socket) do
    socket
    |> discard_exchange()
    |> assign(chat: nil, reply: nil, handle: nil, awaiting_message: nil, page_title: "Chat")
    |> stream(:messages, [], reset: true)
    |> stream(:chats, Chats.list_chats(), reset: true)
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
    socket = assign(socket, :resumes, 0)
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
    |> begin_exchange(chat)
    |> start_stream(chat)
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

  defp start_stream(socket, chat) do
    case Completions.start(chat) do
      {:ok, handle} ->
        assign(socket, handle: handle, reply: Reply.new(chat.model))

      {:error, reason} ->
        reply = Completions.fail(Reply.new(chat.model), reason)

        socket
        |> assign(handle: nil, reply: nil)
        |> store_reply(reply)
    end
  end

  defp store_reply(socket, reply) do
    socket = assign(socket, handle: nil, reply: nil)

    case Completions.finish(socket.assigns.chat, reply) do
      {:ok, %{message: message, chat: chat}} ->
        socket
        |> assign(:chat, chat)
        |> stream_insert(:messages, message)
        |> continue_awaiting(message, reply)

      _ignored_or_failed ->
        discard_exchange(socket)
    end
  end

  # Deciding the last pending call in a turn is what unblocks the
  # conversation, so the next request goes out as soon as none are left.
  defp decide(socket, decision) do
    with %Message{} = awaiting <- socket.assigns.awaiting_message,
         {:ok, message} <- decision.(awaiting) do
      socket
      |> stream_insert(:messages, message)
      |> continue_or_wait(message)
    else
      _nothing_to_decide -> socket
    end
  end

  # Three ways a reply can end: waiting on a human, paused by the API mid
  # server-tool, or done. Only the first stops the conversation.
  defp continue_awaiting(socket, message, reply) do
    cond do
      Approvals.awaiting?(message) ->
        assign(socket, :awaiting_message, message)

      Completions.paused?(message) ->
        socket |> assign(:awaiting_message, nil) |> resume()

      true ->
        socket
        |> end_exchange(message, reply)
        |> assign(awaiting_message: nil, resumes: 0)
    end
  end

  # One span covers everything between a prompt and its answer — every resume,
  # every wait on a human — so the requests and the tool calls it took land in
  # one trace rather than one each.
  defp begin_exchange(socket, chat) do
    params = Completions.params(chat, socket.assigns.model)

    span =
      Tracing.start_conversation(params, session: to_string(chat.id), max_turns: @max_resumes)

    assign(socket, :exchange_span, span)
  end

  defp end_exchange(socket, message, reply) do
    with_span(socket, fn span ->
      if message.error, do: Tracing.set_error(span, message.error)

      Tracing.end_conversation(span, Reply.message(reply), exchange_stop(message))
    end)
  end

  # A stream the user stopped never carried a stop reason from the API, so the
  # app supplied one. It has to translate that back: "cancelled" is not an API
  # reason and the SDK can only read it as :unknown.
  defp exchange_stop(%Message{stop_reason: "cancelled"}), do: :cancelled
  defp exchange_stop(%Message{stop_reason: reason}), do: Claudex.Message.stop(reason)

  # A chat closed or switched part-way leaves a span with no answer to record,
  # only the fact that nobody is waiting for one. Closing it is what hands it
  # to the exporter; dropping it exports nothing.
  defp discard_exchange(socket),
    do: with_span(socket, &Tracing.end_conversation(&1, nil, :abandoned))

  defp with_span(socket, close) do
    case socket.assigns.exchange_span do
      nil ->
        socket

      span ->
        close.(span)
        assign(socket, :exchange_span, nil)
    end
  end

  # A pause resends the history and carries on with nobody deciding anything,
  # so it needs its own ceiling — an API that kept pausing would otherwise
  # loop without end. The count is of pauses in a row: a turn that ends any
  # other way clears it.
  defp resume(socket) do
    if socket.assigns.resumes < @max_resumes do
      socket
      |> update(:resumes, &(&1 + 1))
      |> start_stream(socket.assigns.chat)
    else
      put_flash(socket, :error, "Claude paused #{@max_resumes} times in a row; stopped there.")
    end
  end

  defp continue_or_wait(socket, message) do
    if Approvals.awaiting?(message) do
      assign(socket, :awaiting_message, message)
    else
      socket
      |> assign(awaiting_message: nil, resumes: 0)
      |> start_stream(socket.assigns.chat)
    end
  end

  defp awaiting_message(messages) do
    Enum.find(messages, &(&1.role == "assistant" and Approvals.awaiting?(&1)))
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
