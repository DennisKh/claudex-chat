defmodule ClaudexChat.Completions.Params do
  @moduledoc """
  Turns a chat and its history into the request the Messages API takes.
  """

  alias Claudex.ContentBlock

  alias ClaudexChat.Chats.{Chat, Message, ToolCall}
  alias ClaudexChat.Models.Model
  alias ClaudexChat.{MCP, Paths, Tools}

  @max_tokens 16_384
  @image_types ~w(image/png image/jpeg image/gif image/webp)

  @doc """
  Builds the request body for the next reply in `chat`.

  An assistant turn goes back as the API sent it, block for block, so a
  thinking signature and a web search's encrypted results survive the round
  trip. A reply that arrived with no content — a stream that failed or was
  cancelled before any text — is left out of the history entirely; the API
  rejects a message whose content is empty.

  Thinking is sent as the mode the model actually supports — `"adaptive"` on
  current models, `"enabled"` with a budget on Haiku 4.5 and older. `"off"`
  omits the parameter rather than sending `type: "disabled"`, which some
  models reject outright.

  `display: "summarized"` is explicit because current models default to
  `"omitted"`, which streams thinking blocks with no text in them.

  `cache_control` asks the API to cache the longest prefix it can and move
  the breakpoint along as the chat grows, so a turn re-reads the history
  instead of paying for it again. What makes that work is what this function
  doesn't do: the system prompt and the tool list are the same bytes every
  time, and a turn is only ever appended. Nothing here may start varying per
  request — a timestamp in the system prompt would sit ahead of the whole
  conversation and cache would never be read again.
  """
  @spec build(Chat.t(), [Message.t()], Model.t()) :: map()
  def build(%Chat{} = chat, history, %Model{} = model) do
    mcp = MCP.request_params(chat.mcp_servers)

    %{
      model: chat.model,
      max_tokens: min(@max_tokens, model.max_output_tokens),
      messages: Enum.flat_map(history, &to_param(&1, chat.model)),
      tools: tools(model, Map.get(mcp, :tools, [])),
      system: system(),
      cache_control: %{type: "ephemeral"}
    }
    |> put_mcp_servers(mcp)
    |> put_thinking(chat, model)
  end

  @doc """
  The system prompt.

  Without it Claude assumes the usual chat sandbox — that files arrive as
  uploads and it cannot see a real filesystem — and answers "please upload it"
  instead of reading the file that is sitting right there.
  """
  @spec system() :: String.t()
  def system do
    """
    You are running inside ClaudexChat, a chat app on the user's own computer.

    Your file tools act on real files on that computer. There is no upload
    mechanism and no sandbox: when the user refers to a file, read it rather
    than asking them to paste or attach it.

    The user's project directory is:

        #{Paths.root()}

    Relative paths resolve against it, so `mix.exs` means
    `#{Path.join(Paths.root(), "mix.exs")}`. You may also use absolute paths
    anywhere else the user can reach — another project, `~/Downloads`, and so
    on. Nothing outside the project is off limits by default, but nothing is
    pre-approved either.

    System directories and credential stores are refused outright, whatever
    the user says: #{Enum.join(Enum.take(Paths.denied(), 6), ", ")} and
    similar. Don't try to work around a refusal.

    Use `list_files` when you are unsure what exists rather than guessing at a
    filename, and never claim to have checked what is there unless you ran it.

    Every tool call is shown to the user for approval, with the action and the
    path, before it runs. A denial is their decision, not an error to retry.
    """
  end

  @doc """
  The tools offered for this model: the local file tools and Anthropic's
  hosted web search. Same as `tools/2` with no MCP toolsets.

  Web search comes in two forms and the model decides which. The newer one
  runs code behind the scenes, so it's offered only to models whose
  capabilities report code execution — Haiku 4.5 rejects it outright.
  """
  @spec tools(Model.t()) :: [module() | map()]
  def tools(%Model{} = model), do: tools(model, [])

  @doc "The tools offered for this model, plus one `mcp_toolset` per server `MCP.request_params/1` built."
  @spec tools(Model.t(), [map()]) :: [module() | map()]
  def tools(%Model{} = model, mcp_toolsets) do
    [Tools, %{type: web_search_type(model), name: "web_search"}] ++ mcp_toolsets
  end

  defp web_search_type(%Model{accepts_code_execution: true}), do: "web_search_20260209"
  defp web_search_type(%Model{}), do: "web_search_20250305"

  defp put_mcp_servers(params, %{mcp_servers: servers}),
    do: Map.put(params, :mcp_servers, servers)

  defp put_mcp_servers(params, %{}), do: params

  defp put_thinking(params, %Chat{thinking_mode: "adaptive"}, %Model{} = model) do
    if Model.supports_thinking?(model, "adaptive") do
      Map.put(params, :thinking, %{type: "adaptive", display: "summarized"})
    else
      params
    end
  end

  defp put_thinking(params, %Chat{thinking_mode: "enabled"} = chat, %Model{} = model) do
    budget = min(chat.thinking_budget, params.max_tokens - 1)

    if Model.supports_thinking?(model, "enabled") do
      Map.put(params, :thinking, %{
        type: "enabled",
        budget_tokens: budget,
        display: "summarized"
      })
    else
      params
    end
  end

  defp put_thinking(params, _chat, _model), do: params

  defp to_param(%Message{role: "user"} = message, _model) do
    [Claudex.Message.user(attachment_blocks(message) ++ text_blocks(message.content))]
  end

  defp to_param(%Message{role: "assistant"} = message, model) do
    case assistant_content(message, model) do
      [] -> []
      content -> [Claudex.Message.assistant(content)] ++ tool_result_param(message)
    end
  end

  # A stored turn goes back as the API sent it, block for block: a web search
  # the API ran for itself is only resumable with its own blocks in place, and
  # they can't be rebuilt from the columns beside them. A message stored before
  # those blocks were kept is reassembled from what there is.
  defp assistant_content(%Message{content_blocks: []} = message, model) do
    thinking_block(message, model) ++ text_blocks(message.content) ++ tool_use_blocks(message)
  end

  defp assistant_content(%Message{content_blocks: blocks} = message, model) do
    Enum.filter(blocks, &replayable?(&1, message, model))
  end

  # Thinking is dropped when it came from another model, which the API rejects,
  # or when the stream stopped before the signature that closes it arrived.
  defp replayable?(%{"type" => "thinking"} = block, %Message{model: model}, current_model) do
    model == current_model and block["signature"] not in [nil, ""]
  end

  defp replayable?(%{"type" => "redacted_thinking"}, %Message{model: model}, current_model) do
    model == current_model
  end

  defp replayable?(%{"type" => "text"} = block, _message, _model),
    do: block["text"] not in [nil, ""]

  defp replayable?(%{"type" => "tool_use"}, %Message{} = message, _model),
    do: Message.tool_calls_runnable?(message)

  defp replayable?(_block, _message, _model), do: true

  defp tool_use_blocks(%Message{} = message) do
    if Message.tool_calls_runnable?(message) do
      for call <- message.tool_calls do
        block(%ContentBlock.ToolUse{id: call.call_id, name: call.name, input: call.input})
      end
    else
      []
    end
  end

  # Results go back under role "user" — they're input to Claude, not output
  # from it. A call still waiting on a human has no result to send, so the
  # whole block is held back until every call in the turn is resolved.
  defp tool_result_param(%Message{tool_calls: []}), do: []

  defp tool_result_param(%Message{tool_calls: tool_calls}) do
    if Enum.any?(tool_calls, &ToolCall.pending?/1) do
      []
    else
      [Claudex.Message.tool_results(Enum.map(tool_calls, &tool_result_block/1))]
    end
  end

  defp tool_result_block(%ToolCall{} = call) do
    Claudex.Tool.result(call.call_id, call.output || "", is_error: ToolCall.error?(call))
  end

  defp text_blocks(""), do: []
  defp text_blocks(text), do: [block(%ContentBlock.Text{text: text})]

  defp thinking_block(%Message{thinking: nil}, _model), do: []
  defp thinking_block(%Message{thinking_signature: nil}, _model), do: []

  defp thinking_block(%Message{model: model} = message, current_model)
       when model == current_model do
    [
      block(%ContentBlock.Thinking{
        thinking: message.thinking,
        signature: message.thinking_signature
      })
    ]
  end

  defp thinking_block(_message, _model), do: []

  defp attachment_blocks(%Message{attachments: attachments}) do
    Enum.map(attachments, &block(attachment_block(&1)))
  end

  defp attachment_block(%{mime_type: mime_type, file_id: file_id})
       when mime_type in @image_types do
    ContentBlock.Image.file(file_id)
  end

  defp attachment_block(%{file_id: file_id}), do: ContentBlock.Document.file(file_id)

  # Every block is built as an SDK struct and converted here, so the wire shape
  # stays the SDK's to define.
  defp block(content_block), do: ContentBlock.to_param(content_block)
end
