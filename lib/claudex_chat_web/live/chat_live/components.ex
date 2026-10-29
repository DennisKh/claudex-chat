defmodule ClaudexChatWeb.ChatLive.Components do
  @moduledoc """
  The pieces of the chat page: the chat list, a message, and the composer.
  """

  use ClaudexChatWeb, :html

  alias Claudex.ContentBlock

  alias ClaudexChat.Approvals
  alias ClaudexChat.Chats.{Message, ToolCall}
  alias ClaudexChat.Completions
  alias ClaudexChat.Completions.Reply
  alias ClaudexChat.Models.Model
  alias ClaudexChat.{MCP, Paths, Tools}
  alias ClaudexChatWeb.Markdown

  @thinking_labels %{"off" => "No thinking", "adaptive" => "Adaptive", "enabled" => "Extended"}

  @doc """
  The app's mark: a speech bubble around a prompt caret.

  Inherits `currentColor`, so it takes the colour of whatever it sits in.
  `priv/static/images/icon.svg` is the same drawing, self-coloured, for the
  browser tab.
  """
  def logo(assigns) do
    ~H"""
    <svg
      viewBox="0 0 32 32"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class="size-5"
    >
      <path d="M9 4.5H23A6 6 0 0 1 29 10.5V17.5A6 6 0 0 1 23 23.5H15L9 28.5V23.5A6 6 0 0 1 3 17.5V10.5A6 6 0 0 1 9 4.5Z" />
      <path d="M10.5 11.5 14.5 14 10.5 16.5" />
      <path d="M17.5 16.5H22" />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :chat, :map, required: true
  attr :current_id, :integer, default: nil

  @doc "One row in the sidebar's chat list."
  def chat_row(assigns) do
    ~H"""
    <div id={@id} class="group relative">
      <.link
        patch={~p"/chats/#{@chat.id}"}
        class={[
          "block truncate rounded-lg px-3 py-2 pr-9 text-sm transition-colors",
          @chat.id == @current_id && "bg-base-100 font-medium shadow-sm",
          @chat.id != @current_id && "text-base-content/70 hover:bg-base-100/60"
        ]}
      >
        {@chat.title}
      </.link>
      <button
        type="button"
        id={"delete-chat-#{@chat.id}"}
        phx-click="delete_chat"
        phx-value-id={@chat.id}
        data-confirm="Delete this chat?"
        aria-label={"Delete #{@chat.title}"}
        class="absolute right-1.5 top-1/2 hidden size-6 -translate-y-1/2 items-center justify-center rounded text-base-content/40 hover:bg-base-300 hover:text-error group-hover:flex"
      >
        <.icon name="hero-trash-micro" class="size-4" />
      </button>
    </div>
    """
  end

  attr :message, Message, required: true

  @doc "A stored turn, from either side of the conversation."
  def message(%{message: %Message{role: "user"}} = assigns) do
    ~H"""
    <div class="group flex items-end justify-end gap-1.5">
      <button
        type="button"
        id={"replay-#{@message.id}"}
        phx-click="replay"
        phx-value-id={@message.id}
        title="Send this message again"
        aria-label="Send this message again"
        class="mb-0.5 flex size-7 shrink-0 items-center justify-center rounded-lg text-base-content/40 opacity-0 transition-opacity hover:bg-base-200 hover:text-base-content group-hover:opacity-100"
      >
        <.icon name="hero-arrow-path-micro" class="size-3.5" />
      </button>
      <div class="max-w-[85%] space-y-2">
        <div :if={@message.attachments != []} class="flex flex-wrap justify-end gap-1.5">
          <span
            :for={attachment <- @message.attachments}
            class="inline-flex items-center gap-1 rounded-md bg-base-200 px-2 py-1 font-mono text-xs text-base-content/70"
          >
            <.icon name="hero-paper-clip-micro" class="size-3" />
            {attachment.filename}
          </span>
        </div>
        <div
          class="whitespace-pre-wrap rounded-2xl bg-base-200 px-4 py-2 text-sm leading-relaxed"
          phx-no-format
        >{@message.content}</div>
      </div>
    </div>
    """
  end

  def message(%{message: %Message{role: "assistant"}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <.thinking_panel :if={@message.thinking} thinking={@message.thinking} open={false} />

      <div :if={@message.error} class="rounded-lg border border-error/30 bg-error/5 px-4 py-3 text-sm">
        <div class="mb-1 flex items-center gap-1.5 font-medium text-error">
          <.icon name="hero-exclamation-triangle-micro" class="size-4" /> The reply failed
        </div>
        <p class="font-mono text-xs text-base-content/70">{@message.error}</p>
      </div>

      <div :if={@message.content != ""} class="prose-chat text-sm leading-relaxed">
        {Markdown.to_html(@message.content)}
      </div>

      <.mcp_calls message={@message} />

      <.tool_calls message={@message} />

      <.usage message={@message} />

      <button
        :if={retryable?(@message)}
        type="button"
        id={"retry-#{@message.id}"}
        phx-click="retry"
        phx-value-id={@message.id}
        title="Discard this reply and ask again"
        class="flex h-7 items-center gap-1.5 rounded-lg border border-base-300 px-3 text-xs font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-arrow-path-micro" class="size-3.5" /> Retry
      </button>
    </div>
    """
  end

  attr :message, Message, required: true

  @doc """
  What the reply cost and how long it took.

  Counters the API didn't report are left out rather than shown as zero. A
  reply whose cache counters were both reported as zero says so.
  """
  def usage(assigns) do
    ~H"""
    <div class="usage-meta flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-[11px] text-base-content/40">
      <span :if={@message.model}>{@message.model}</span>
      <span :if={@message.input_tokens}>{@message.input_tokens} in</span>
      <span :if={@message.output_tokens}>{@message.output_tokens} out</span>
      <span :if={@message.cache_creation_tokens && @message.cache_creation_tokens > 0}>
        {@message.cache_creation_tokens} cache write
      </span>
      <span :if={@message.cache_read_tokens && @message.cache_read_tokens > 0}>
        {@message.cache_read_tokens} cache read
      </span>
      <span
        :if={Completions.uncached?(@message)}
        title="Caching was requested, and this request neither wrote nor read the cache"
      >
        uncached
      </span>
      <span :if={@message.duration_ms}>{format_duration(@message.duration_ms)}</span>
      <span :if={@message.stop_reason == "cancelled"} class="text-warning">stopped</span>
      <span :if={Completions.truncated?(@message)} class="text-warning">
        truncated — hit the token ceiling
      </span>
    </div>
    """
  end

  attr :reply, Reply, required: true

  @doc """
  The reply as it streams in.

  Renders as plain text rather than Markdown: the document is still being
  written, so half of it doesn't parse yet, and re-rendering on every delta
  would mean a Markdown pass per token.

  Something is always moving until the first token of the answer lands. A turn
  that thinks and then goes quiet — running a search, deciding on a tool — is
  still working, and a panel of finished reasoning on its own reads as a reply
  that stopped.
  """
  def streaming_reply(assigns) do
    assigns = assign(assigns, Reply.preview(assigns.reply))

    ~H"""
    <div class="space-y-2">
      <.thinking_panel :if={@thinking != ""} thinking={@thinking} open={@text == ""} />

      <div :if={@text != ""} class="whitespace-pre-wrap text-sm leading-relaxed" phx-no-format>{@text}<span class="ml-0.5 inline-block h-4 w-[2px] animate-pulse bg-base-content/60 align-text-bottom" /></div>

      <div :if={@text == ""} class="flex items-center gap-2 text-sm text-base-content/50">
        <.icon name="hero-arrow-path" class="size-4 animate-spin" /> {waiting_label(@thinking)}
      </div>
    </div>
    """
  end

  attr :thinking, :string, required: true
  attr :open, :boolean, default: false

  @doc "Claude's reasoning, folded away by default."
  def thinking_panel(assigns) do
    ~H"""
    <details open={@open} class="rounded-lg border border-base-300 bg-base-200/40">
      <summary class="cursor-pointer select-none px-3 py-1.5 font-mono text-[11px] uppercase tracking-wide text-base-content/50 hover:text-base-content/80">
        Thinking
      </summary>
      <div
        class="whitespace-pre-wrap border-t border-base-300 px-3 py-2 text-xs leading-relaxed text-base-content/60"
        phx-no-format
      >{@thinking}</div>
    </details>
    """
  end

  attr :message, Message, required: true

  @doc """
  Calls Claude made to a tool on an MCP server, paired with their results and
  collapsed by default.

  These ran on Anthropic's own infrastructure during the reply, the same way
  a web search does — there was no approval step, unlike `tool_calls/1`.
  """
  def mcp_calls(assigns) do
    assigns = assign(assigns, :calls, mcp_call_pairs(assigns.message))

    ~H"""
    <div :if={@calls != []} class="space-y-2">
      <details
        :for={{use, result} <- @calls}
        class="rounded-lg border border-base-300 bg-base-200/40"
      >
        <summary class="flex cursor-pointer select-none items-center gap-2 px-3 py-1.5 font-mono text-[11px] text-base-content/50 hover:text-base-content/80">
          <.icon name="hero-puzzle-piece-micro" class="size-3.5" />
          <span>{use["server_name"]} · {use["name"]}</span>
          <span :if={result && result["is_error"]} class="text-error">failed</span>
        </summary>
        <div class="space-y-2 border-t border-base-300 px-3 py-2">
          <pre
            class="overflow-x-auto font-mono text-[11px] leading-relaxed text-base-content/60"
            phx-no-curly-interpolation
          ><%= JSON.encode!(use["input"] || %{}) %></pre>
          <pre
            :if={result}
            class="max-h-64 overflow-auto font-mono text-[11px] leading-relaxed text-base-content/60"
            phx-no-curly-interpolation
          ><%= mcp_result_text(result) %></pre>
        </div>
      </details>
    </div>
    """
  end

  attr :message, Message, required: true

  @doc """
  The approval gate: what Claude wants to run, and the two buttons that decide
  it. Calls already decided show what happened instead.
  """
  def tool_calls(assigns) do
    assigns =
      assign(assigns, :pending, MapSet.new(Approvals.pending(assigns.message), & &1.call_id))

    ~H"""
    <div :if={@message.tool_calls != []} class="space-y-2">
      <div
        :for={call <- @message.tool_calls}
        class={[
          "rounded-lg border text-sm",
          call.status == "pending" && "border-warning/40 bg-warning/5",
          call.status != "pending" && "border-base-300 bg-base-200/40"
        ]}
      >
        <div class="flex items-start gap-2 px-3 py-2">
          <.icon name={tool_icon(call.name)} class="mt-0.5 size-4 shrink-0 text-base-content/50" />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="text-xs font-semibold">{tool_verb(call.name)}</span>
              <span
                :if={outside_root?(call)}
                class="rounded bg-warning/20 px-1.5 py-0.5 font-mono text-[10px] text-warning"
              >
                outside project
              </span>
            </div>
            <div class="mt-0.5 break-all font-mono text-[11px] text-base-content/60">
              {tool_path(call)}
            </div>
          </div>
          <span
            :if={call.status != "pending"}
            class={["shrink-0 font-mono text-[11px]", status_class(call.status)]}
          >
            {call.status}
          </span>
        </div>

        <pre
          class="overflow-x-auto border-t border-base-300 px-3 py-2 font-mono text-[11px] leading-relaxed text-base-content/60"
          phx-no-curly-interpolation
        ><%= tool_input(call) %></pre>

        <div
          :if={call.status == "approved" and not ToolCall.answered?(call)}
          class="border-t border-base-300 px-3 py-2 text-xs text-base-content/50"
        >
          Runs once every call in this reply is decided.
        </div>

        <div
          :if={MapSet.member?(@pending, call.call_id)}
          class="flex items-center gap-2 border-t border-warning/30 px-3 py-2"
        >
          <button
            type="button"
            id={"approve-#{call.call_id}"}
            phx-click="approve_tool"
            phx-value-id={call.call_id}
            class="flex h-7 items-center gap-1.5 rounded-lg bg-base-content px-3 text-xs font-medium text-base-100 hover:opacity-80"
          >
            <.icon name="hero-check-micro" class="size-3.5" /> Approve
          </button>
          <button
            type="button"
            id={"deny-#{call.call_id}"}
            phx-click="deny_tool"
            phx-value-id={call.call_id}
            class="flex h-7 items-center gap-1.5 rounded-lg bg-base-200 px-3 text-xs font-medium hover:bg-base-300"
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" /> Deny
          </button>
        </div>

        <div
          :if={call.status != "pending" and call.output not in [nil, ""]}
          class="border-t border-base-300"
        >
          <details>
            <summary class="cursor-pointer select-none px-3 py-1.5 font-mono text-[11px] text-base-content/50 hover:text-base-content/80">
              Result
            </summary>
            <pre
              class="max-h-64 overflow-auto border-t border-base-300 px-3 py-2 font-mono text-[11px] leading-relaxed text-base-content/60"
              phx-no-curly-interpolation
            ><%= call.output %></pre>
          </details>
        </div>
      </div>
    </div>
    """
  end

  attr :model_groups, :list, required: true
  attr :model, Model, required: true
  attr :thinking_mode, :string, required: true
  attr :uploads, :map, required: true
  attr :streaming, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :content, :string, default: ""
  attr :mcp_servers, :list, default: []
  attr :mcp_menu_open, :boolean, default: false

  @doc "The prompt box and the controls under it."
  def composer(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-100 px-4 py-3">
      <div class="mx-auto max-w-3xl">
        <form id="composer" phx-submit="send" phx-change="composer_change">
          <div class="rounded-2xl border border-base-300 bg-base-100 shadow-sm focus-within:border-base-content/30">
            <.upload_previews uploads={@uploads} />

            <textarea
              id="prompt"
              name="content"
              rows="2"
              phx-hook=".SubmitOnEnter"
              phx-debounce="blur"
              disabled={@disabled}
              placeholder={
                if @disabled, do: "Set ANTHROPIC_API_KEY to start chatting", else: "Ask anything…"
              }
              class="w-full resize-none bg-transparent px-4 pt-3 pb-2 text-sm leading-relaxed placeholder:text-base-content/30 focus:outline-none disabled:cursor-not-allowed"
            >{@content}</textarea>

            <div class="flex items-center gap-2 px-3 pb-3">
              <select
                id="model-select"
                name="model"
                phx-change="set_model"
                disabled={@streaming}
                class="h-8 max-w-[14rem] truncate rounded-lg bg-base-200 px-2.5 font-mono text-xs text-base-content/70 hover:bg-base-300 focus:outline-none disabled:opacity-50"
              >
                <optgroup :for={{family, models} <- @model_groups} label={family}>
                  <option :for={model <- models} value={model.id} selected={model.id == @model.id}>
                    {model_label(model)}
                  </option>
                </optgroup>
              </select>

              <select
                id="thinking-select"
                name="thinking"
                phx-change="set_thinking"
                disabled={@streaming or length(@model.thinking_modes) == 1}
                class="h-8 rounded-lg bg-base-200 px-2.5 font-mono text-xs text-base-content/70 hover:bg-base-300 focus:outline-none disabled:opacity-50"
              >
                <option
                  :for={mode <- @model.thinking_modes}
                  value={mode}
                  selected={mode == @thinking_mode}
                >
                  {thinking_label(mode)}
                </option>
              </select>

              <label
                for={@uploads.attachments.ref}
                title="Attach a file"
                class="flex size-8 cursor-pointer items-center justify-center rounded-lg text-base-content/50 hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-paper-clip" class="size-4" />
                <.live_file_input upload={@uploads.attachments} class="sr-only" />
              </label>

              <div class="relative">
                <button
                  type="button"
                  id="mcp-toggle"
                  phx-click="toggle_mcp_menu"
                  disabled={@streaming}
                  title="MCP servers"
                  aria-label="MCP servers"
                  class={[
                    "flex h-8 items-center gap-1 rounded-lg px-2 hover:bg-base-200 disabled:opacity-50",
                    @mcp_servers == [] && "text-base-content/50 hover:text-base-content",
                    @mcp_servers != [] && "text-base-content"
                  ]}
                >
                  <.icon name="hero-puzzle-piece" class="size-4" />
                  <span :if={@mcp_servers != []} class="font-mono text-[11px]">
                    {length(@mcp_servers)}
                  </span>
                </button>

                <.mcp_menu :if={@mcp_menu_open} chat_mcp_servers={@mcp_servers} />
              </div>

              <div class="flex-1"></div>

              <button
                :if={@streaming}
                type="button"
                id="stop"
                phx-click="cancel"
                class="flex h-8 items-center gap-1.5 rounded-lg bg-base-200 px-3 text-xs font-medium hover:bg-base-300"
              >
                <.icon name="hero-stop-micro" class="size-3.5" /> Stop
              </button>

              <button
                :if={!@streaming}
                type="submit"
                id="send"
                disabled={@disabled}
                class="flex size-8 items-center justify-center rounded-lg bg-base-content text-base-100 transition-opacity hover:opacity-80 disabled:opacity-30"
              >
                <.icon name="hero-arrow-up-micro" class="size-4" />
              </button>
            </div>
          </div>
        </form>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
          export default {
            mounted() {
              this.el.addEventListener("keydown", (event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault()
                  this.el.form.requestSubmit()
                }
              })
              this.handleEvent("chat:sent", () => { this.el.value = ""; this.el.focus() })
            }
          }
        </script>
      </div>
    </div>
    """
  end

  attr :chat_mcp_servers, :list, required: true

  # The composer's MCP panel: every server in the catalogue, with a toggle
  # for whether this chat has it enabled.
  defp mcp_menu(assigns) do
    assigns = assign(assigns, :servers, MCP.servers())

    ~H"""
    <div
      id="mcp-menu"
      phx-click-away="toggle_mcp_menu"
      class="absolute bottom-full left-0 z-10 mb-2 w-72 rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg"
    >
      <p class="px-1 pb-2 text-[11px] leading-relaxed text-base-content/50">
        These run on Anthropic's servers during the reply, like web search — there's no approval step.
      </p>

      <button
        :for={server <- @servers}
        type="button"
        id={"mcp-server-#{server.name}"}
        phx-click="toggle_mcp"
        phx-value-name={server.name}
        class="flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left hover:bg-base-200"
      >
        <span class={[
          "mt-0.5 flex size-4 shrink-0 items-center justify-center rounded border",
          server.name in @chat_mcp_servers && "border-base-content bg-base-content",
          server.name not in @chat_mcp_servers && "border-base-300"
        ]}>
          <.icon
            :if={server.name in @chat_mcp_servers}
            name="hero-check-micro"
            class="size-3 text-base-100"
          />
        </span>
        <span class="min-w-0">
          <span class="block font-mono text-xs font-medium">{server.label}</span>
          <span class="block text-[11px] text-base-content/50">{server.description}</span>
        </span>
      </button>
    </div>
    """
  end

  attr :uploads, :map, required: true

  defp upload_previews(assigns) do
    ~H"""
    <div :if={@uploads.attachments.entries != []} class="flex flex-wrap gap-2 px-3 pt-3">
      <div
        :for={entry <- @uploads.attachments.entries}
        class="flex items-center gap-2 rounded-lg bg-base-200 px-2 py-1 font-mono text-xs"
      >
        <.icon name="hero-document-micro" class="size-3.5 text-base-content/50" />
        <span class="max-w-[12rem] truncate">{entry.client_name}</span>
        <span :if={entry.progress > 0 and entry.progress < 100} class="text-base-content/40">
          {entry.progress}%
        </span>
        <button
          type="button"
          phx-click="drop_upload"
          phx-value-ref={entry.ref}
          aria-label={"Remove #{entry.client_name}"}
          class="text-base-content/40 hover:text-error"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  defp thinking_label(mode), do: Map.fetch!(@thinking_labels, mode)

  defp model_label(model) do
    case Model.lifecycle_note(model) do
      nil -> model.display_name
      note -> "#{model.display_name} (#{note})"
    end
  end

  defp waiting_label(""), do: "Waiting for the first token"
  defp waiting_label(_thinking), do: "Working on it"

  # Asking again can clear a cancelled or failed reply, and can clear this
  # request's own token ceiling. It can't clear the model's context window:
  # the history that overflowed it is the history the retry would resend.
  defp retryable?(%Message{stop_reason: "cancelled"}), do: true
  defp retryable?(%Message{error: error}) when not is_nil(error), do: true
  defp retryable?(%Message{stop_reason: "max_tokens"}), do: true
  defp retryable?(%Message{}), do: false

  defp tool_icon("read_file"), do: "hero-document-text-micro"
  defp tool_icon("write_file"), do: "hero-pencil-square-micro"
  defp tool_icon("edit_file"), do: "hero-pencil-micro"
  defp tool_icon("apply_edits"), do: "hero-pencil-micro"
  defp tool_icon("list_files"), do: "hero-folder-open-micro"
  defp tool_icon(_name), do: "hero-wrench-screwdriver-micro"

  defp tool_verb("read_file"), do: "Read file"
  defp tool_verb("write_file"), do: "Write file"
  defp tool_verb("edit_file"), do: "Edit file"
  defp tool_verb("apply_edits"), do: "Apply edits"
  defp tool_verb("list_files"), do: "List directory"
  defp tool_verb(name), do: name

  defp tool_path(call), do: Tools.path_of(call.name, call.input) || "(no path)"

  defp outside_root?(call) do
    case Tools.path_of(call.name, call.input) do
      nil -> false
      path -> path |> Path.expand(Paths.root()) |> Paths.outside_root?()
    end
  end

  defp tool_input(%{input: input}), do: JSON.encode!(input)

  # `content_blocks` is stored as the API's own JSON, string keys included, so
  # it's read directly here rather than decoded into SDK structs first.
  defp mcp_call_pairs(%Message{content_blocks: blocks}) do
    results = Enum.filter(blocks, &(&1["type"] == "mcp_tool_result"))

    blocks
    |> Enum.filter(&(&1["type"] == "mcp_tool_use"))
    |> Enum.map(fn use -> {use, Enum.find(results, &(&1["tool_use_id"] == use["id"]))} end)
  end

  # A stored block is the API's own JSON, so it goes back through the SDK to be
  # read: the shape of an MCP result is the SDK's to know, not this module's.
  defp mcp_result_text(result) do
    result |> ContentBlock.decode() |> ContentBlock.MCPToolResult.text()
  end

  defp status_class("approved"), do: "text-success"
  defp status_class("denied"), do: "text-warning"
  defp status_class("failed"), do: "text-error"
  defp status_class(_status), do: "text-base-content/40"

  defp format_duration(ms) when ms < 1000, do: "#{ms} ms"
  defp format_duration(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"
end
