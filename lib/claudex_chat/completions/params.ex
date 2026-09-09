defmodule ClaudexChat.Completions.Params do
  @moduledoc """
  Turns a chat and its history into the request the Messages API takes.
  """

  alias Claudex.ContentBlock

  alias ClaudexChat.Chats.{Chat, Message, ToolCall}
  alias ClaudexChat.Models.Model
  alias ClaudexChat.{Paths, Tools}

  @max_tokens 16_384
  @image_types ~w(image/png image/jpeg image/gif image/webp)

  @doc """
  Builds the request body for the next reply in `chat`.

  A reply that arrived with no content — a stream that failed or was cancelled
  before any text — is left out of the history entirely; the API rejects a
  message whose content is empty.

  Thinking is sent as the mode the model actually supports — `"adaptive"` on
  current models, `"enabled"` with a budget on Haiku 4.5 and older. `"off"`
  omits the parameter rather than sending `type: "disabled"`, which some
  models reject outright.

  `display: "summarized"` is explicit because current models default to
  `"omitted"`, which streams thinking blocks with no text in them.
  """
  @spec build(Chat.t(), [Message.t()], Model.t()) :: map()
  def build(%Chat{} = chat, history, %Model{} = model) do
    %{
      model: chat.model,
      max_tokens: min(@max_tokens, model.max_output_tokens),
      messages: Enum.flat_map(history, &to_param(&1, chat.model)),
      tools: tools(model),
      system: system()
    }
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
  The tools offered for this model: the local file tools, plus Anthropic's
  hosted web search.

  Web search comes in two forms and the model decides which. The newer one
  runs code behind the scenes, so it's offered only to models whose
  capabilities report code execution — Haiku 4.5 rejects it outright.
  """
  @spec tools(Model.t()) :: [module() | map()]
  def tools(%Model{} = model) do
    [Tools, %{type: web_search_type(model), name: "web_search"}]
  end

  defp web_search_type(%Model{accepts_code_execution: true}), do: "web_search_20260209"
  defp web_search_type(%Model{}), do: "web_search_20250305"

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
    content =
      thinking_block(message, model) ++
        text_blocks(message.content) ++ tool_use_blocks(message)

    case content do
      [] -> []
      content -> [Claudex.Message.assistant(content)] ++ tool_result_param(message)
    end
  end

  defp tool_use_blocks(%Message{tool_calls: tool_calls}) do
    for call <- tool_calls do
      block(%ContentBlock.ToolUse{id: call.call_id, name: call.name, input: call.input})
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
    Enum.map(attachments, fn attachment ->
      %{
        type: block_type(attachment.mime_type),
        source: %{type: "file", file_id: attachment.file_id}
      }
    end)
  end

  # Content blocks are built as SDK structs and converted here, so the wire
  # shape stays the SDK's to define. Attachments have no struct — the API takes
  # those blocks verbatim.
  defp block(content_block), do: ContentBlock.to_param(content_block)

  defp block_type(mime_type) when mime_type in @image_types, do: "image"
  defp block_type(_mime_type), do: "document"
end
