defmodule ClaudexChat.Tools.Edit do
  @moduledoc """
  One replacement in an `apply_edits` call: the exact text to find and the
  text to put in its place.

  It only shapes the schema Claude is sent. The tool receives each edit as
  the decoded JSON map, with string keys.
  """

  use Claudex.Schema

  defstruct [:old_string, :new_string]

  @type t :: %__MODULE__{old_string: String.t(), new_string: String.t()}
end
