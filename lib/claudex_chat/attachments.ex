defmodule ClaudexChat.Attachments do
  @moduledoc """
  Puts files on the Claude Files API so a message can reference them by id
  instead of carrying the bytes.

  The bytes live with Anthropic; a chat message keeps only the id, name, type
  and size.
  """

  alias Claudex.{FileMetadata, Files}
  alias ClaudexChat.Claude

  @doc """
  Uploads one file and returns the attributes to embed on a message.

  `content_type` is what the browser reported. The API detects the type
  itself when that's missing.
  """
  @spec upload(Path.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def upload(path, filename, content_type) do
    with {:ok, client} <- Claude.client(),
         {:ok, content} <- File.read(path),
         {:ok, %FileMetadata{} = file} <-
           Files.upload(client, {content, filename}, upload_options(content_type)) do
      {:ok,
       %{
         file_id: file.id,
         filename: file.filename,
         mime_type: file.mime_type,
         size_bytes: file.size_bytes
       }}
    end
  end

  @doc "Removes a file from the Files API, ignoring one that's already gone."
  @spec delete(String.t()) :: :ok
  def delete(file_id) do
    with {:ok, client} <- Claude.client() do
      Files.delete(client, file_id)
    end

    :ok
  end

  defp upload_options(nil), do: []
  defp upload_options(content_type), do: [content_type: content_type]
end
