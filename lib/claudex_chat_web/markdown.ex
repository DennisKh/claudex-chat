defmodule ClaudexChatWeb.Markdown do
  @moduledoc """
  Renders a reply's Markdown to HTML for the message list.

  The output is sanitized: a model can write raw HTML, and none of it should
  reach the page as markup.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  @doc """
  Converts Markdown to safe HTML.

  Falls back to the plain text, escaped, if the document can't be parsed —
  a reply is worth showing even when its formatting isn't.
  """
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: Phoenix.HTML.raw("")

  def to_html(markdown) do
    case MDEx.to_html(markdown, options()) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _reason} -> Phoenix.HTML.html_escape(markdown)
    end
  end

  defp options do
    [extension: @extension, sanitize: MDEx.Document.default_sanitize_options()]
  end
end
