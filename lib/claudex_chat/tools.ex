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
  # shows the path on the approval prompt and the names are not uniform.
  @path_arguments %{
    "read_file" => "filename_or_path",
    "write_file" => "path",
    "edit_file" => "path",
    "list_files" => "path"
  }

  @doc "The path a call is about, for showing on the approval prompt."
  @spec path_of(String.t(), map()) :: String.t() | nil
  def path_of(tool, input) when is_map(input), do: input[@path_arguments[tool]]

  @doc """
  List the files and directories at a path on the user's machine.

  Use this to find out what is actually there before reading or writing —
  when a path might be wrong, when the user names a directory rather than a
  file, or when you would otherwise be guessing at a filename.

  Directories are marked with a trailing `/`. The listing is one level deep
  and is not recursive; list a subdirectory to go deeper. System directories
  and credential stores are refused whatever the user approves.
  """
  @tool true
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
  Read a UTF-8 text file from the user local machine workspace and return its full contents.

  Use this to read a file when user provide you a file name or a file path on his local filesystem.

  Use this before editing a file, and whenever an answer depends on what a
  file actually contains — never describe a file you have not read.

  Relative paths resolve against the project directory. Files above 200,000 bytes are
  refused rather than truncated, so the contents you get back are always the
  whole file. This reads text; it does not decode images, PDFs or other
  binaries.
  """
  @tool true
  @spec read_file(String.t()) :: String.t()
  def read_file(filename_or_path) do
    file = resolve!(filename_or_path)

    case File.stat(file) do
      {:ok, %File.Stat{type: :directory}} ->
        raise Claudex.Tool.Error, "#{filename_or_path} is a directory, not a file"

      {:ok, %File.Stat{size: size}} when size > @max_read_bytes ->
        raise Claudex.Tool.Error,
              "#{filename_or_path} is #{size} bytes, over the #{@max_read_bytes} byte limit"

      {:ok, _stat} ->
        read!(file, filename_or_path)

      {:error, reason} ->
        raise Claudex.Tool.Error, "can't read #{filename_or_path}: #{:file.format_error(reason)}"
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
  @tool true
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
  @tool true
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
