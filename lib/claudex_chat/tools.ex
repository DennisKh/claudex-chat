defmodule ClaudexChat.Tools do
  @moduledoc """
  The tools Claude can ask to run on this machine.

  Every path goes through `ClaudexChat.Paths` first, which refuses system
  directories and credential stores outright. A refusal is raised as
  `Claudex.Tool.Error`, which reaches Claude as a tool result it can read and
  work around rather than as a crash.

  Everywhere else is reachable — another project, `~/Downloads` — and nothing
  here checks for approval. `ClaudexChat.Approvals` is what decides whether a
  call runs at all, and no path is pre-authorised.
  """

  use Claudex.Tool

  alias ClaudexChat.Paths

  @max_read_bytes 200_000
  @max_entries 500

  # Which argument carries the path, per tool. One home for it, because the UI
  # shows the path on the approval prompt and a tool is free to name the
  # argument something other than "path".
  @path_arguments %{
    "read_file" => "path",
    "write_file" => "path",
    "edit_file" => "path",
    "list_files" => "path"
  }

  @doc """
  The path a call is about, for showing on the approval prompt.

  `nil` for a tool that has no path argument, or a call whose input is missing
  it — the prompt says so rather than inventing one.
  """
  @spec path_of(String.t(), map()) :: String.t() | nil
  def path_of(tool, input) when is_map(input) do
    case @path_arguments[tool] do
      nil -> nil
      argument -> input[argument]
    end
  end

  @doc """
  List the files and directories at a path on the user's machine.

  Use this to find out what is actually there before reading or writing —
  when a path might be wrong, when the user names a directory rather than a
  file, or when you would otherwise be guessing at a filename.

  Directories are marked with a trailing `/`. The listing is one level deep
  and is not recursive; list a subdirectory to go deeper. System directories
  and credential stores are refused whatever the user approves.
  """
  @tool %{
    args: [
      path:
        "Directory to list. Absolute, or relative to the project directory (\".\" for the project itself)."
    ]
  }
  @spec list_files(String.t()) :: String.t()
  def list_files(path) do
    dir = resolve!(path)

    case File.ls(dir) do
      {:ok, entries} ->
        format_entries(dir, path, entries)

      {:error, :enotdir} ->
        raise Claudex.Tool.Error, "#{path} is a file, not a directory"

      {:error, reason} ->
        raise Claudex.Tool.Error, "can't list #{path}: #{:file.format_error(reason)}"
    end
  end

  defp format_entries(_dir, path, []), do: "#{path} is empty"

  defp format_entries(dir, path, entries) do
    listing =
      entries
      |> Enum.sort()
      |> Enum.take(@max_entries)
      |> Enum.map_join("\n", &entry_line(dir, &1))

    header = "#{path} (#{length(entries)} entries)"

    if length(entries) > @max_entries do
      "#{header}, first #{@max_entries} shown:\n#{listing}"
    else
      "#{header}:\n#{listing}"
    end
  end

  defp entry_line(dir, entry) do
    if File.dir?(Path.join(dir, entry)), do: entry <> "/", else: entry
  end

  @doc """
  Read a text file on the user's machine and return its full contents.

  Use this whenever an answer depends on what a file actually contains, and
  always before editing one — never describe a file you have not read. The
  file is already on this machine, so read it rather than asking the user to
  paste or upload it.

  Relative paths resolve against the project directory. This reads UTF-8 text;
  it does not decode images, PDFs or other binaries, and a file above 200,000
  bytes is refused rather than truncated, so what you get back is always the
  whole file.
  """
  @tool %{
    args: [
      path:
        "File to read. Absolute, or relative to the project directory (\"mix.exs\", \"lib/app.ex\")."
    ]
  }
  @spec read_file(String.t()) :: String.t()
  def read_file(path) do
    file = resolve!(path)

    case File.stat(file) do
      {:ok, %File.Stat{type: :directory}} ->
        raise Claudex.Tool.Error, "#{path} is a directory, not a file"

      {:ok, %File.Stat{size: size}} when size > @max_read_bytes ->
        raise Claudex.Tool.Error,
              "#{path} is #{size} bytes, over the #{@max_read_bytes} byte limit"

      {:ok, _stat} ->
        read!(file, path)

      {:error, reason} ->
        raise Claudex.Tool.Error, "can't read #{path}: #{:file.format_error(reason)}"
    end
  end

  @doc """
  Write text to a file on the user's machine, creating it or replacing its entire
  contents. Missing parent directories are created.

  Use this to create a new file, or when replacing a whole file is genuinely
  simpler than editing it.

  Do not use it to change part of an existing file: it overwrites everything,
  so any content you have not read is lost. Read the file and use `edit_file`
  instead. `content` is the complete final text of the file — not a fragment,
  a patch, or a diff.
  """
  @tool %{
    args: [
      path:
        "File to write. Absolute, or relative to the project directory. Parent directories are created.",
      content: "The complete final text of the file. Not a fragment, a patch, or a diff."
    ]
  }
  @spec write_file(String.t(), String.t()) :: String.t()
  def write_file(path, content) do
    file = resolve!(path)
    File.mkdir_p!(Path.dirname(file))

    case File.write(file, content) do
      :ok ->
        "wrote #{byte_size(content)} bytes to #{path}"

      {:error, reason} ->
        raise Claudex.Tool.Error, "can't write #{path}: #{:file.format_error(reason)}"
    end
  end

  @doc """
  Replace one exact occurrence of `old_string` with `new_string` in a
  file on the user's machine.

  Use this for any change to a file that already exists. Read the file first
  so `old_string` matches byte for byte, indentation included.

  `old_string` must appear exactly once. The edit is refused when it is
  missing or ambiguous, which means a failed edit is a signal to include more
  surrounding lines — not to retry the same short string. Both arguments are
  literal text, not regular expressions and not diff syntax. To create a file,
  use `write_file`.
  """
  @tool %{
    args: [
      path: "File to edit. Absolute, or relative to the project directory.",
      old_string:
        "Exact text to replace, matching the file byte for byte including indentation. Must appear exactly once.",
      new_string:
        "Literal text to put in its place. Not a regular expression and not diff syntax."
    ]
  }
  @spec edit_file(String.t(), String.t(), String.t()) :: String.t()
  def edit_file(path, old_string, new_string) do
    file = resolve!(path)
    content = read!(file, path)

    case occurrences(content, old_string) do
      0 -> raise Claudex.Tool.Error, "old_string does not appear in #{path}"
      1 -> replace!(file, path, content, old_string, new_string)
      n -> raise Claudex.Tool.Error, "old_string appears #{n} times in #{path}; make it unique"
    end
  end

  defp replace!(file, path, content, old_string, new_string) do
    File.write!(file, String.replace(content, old_string, new_string))

    "replaced 1 occurrence in #{path}"
  end

  defp occurrences(content, string) do
    content |> String.split(string) |> length() |> Kernel.-(1)
  end

  defp read!(file, path) do
    case File.read(file) do
      {:ok, content} ->
        content

      {:error, reason} ->
        raise Claudex.Tool.Error, "can't read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp resolve!(path) do
    case Paths.resolve(path) do
      {:ok, file} ->
        file

      {:error, :denied} ->
        raise Claudex.Tool.Error,
              "#{path} is a system or credential location and is never readable or writable"
    end
  end
end
