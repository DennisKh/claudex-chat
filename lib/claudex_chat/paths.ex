defmodule ClaudexChat.Paths do
  @moduledoc """
  Where the file tools may and may not go.

  There is no sandbox. Anything the OS user can reach is *reachable* — another
  project, `~/Downloads` — and what allows a particular path is the human
  approving that call, not a directory boundary. Nothing is pre-authorised.

  What this module does enforce is a deny list: system directories and
  credential stores that no approval can unlock. Those are refused before the
  approval is even offered.

  Relative paths resolve against `root/0`, which is the project directory
  unless `config :claudex_chat, default_root:` says otherwise. Extra denials
  go in `config :claudex_chat, denied_paths:`.
  """

  @denied_absolute ~w(
    /bin /boot /dev /etc /proc /sbin /sys /usr
    /System /Library /Volumes/Preboot
    /var/db /var/root
  )

  @denied_in_home ~w(
    .ssh .aws .gnupg .docker .kube .config/anthropic .config/gcloud .claude
    Library/Keychains Library/Group\ Containers
  )

  @doc "The directory relative paths resolve against."
  @spec root() :: Path.t()
  def root do
    :claudex_chat
    |> Application.get_env(:default_root, File.cwd!())
    |> Path.expand()
  end

  @doc """
  Turns a tool-supplied path into an absolute one, or refuses it.

  Symlinks are followed before the deny list is applied, so a link pointing
  into a denied directory is refused too.
  """
  @spec resolve(String.t()) :: {:ok, Path.t()} | {:error, :denied}
  def resolve(path) when is_binary(path) do
    resolved = path |> Path.expand(root()) |> real_path()

    if denied?(resolved), do: {:error, :denied}, else: {:ok, resolved}
  end

  @doc """
  Whether this absolute path is one no approval can unlock.

  Denied prefixes are resolved before comparing, because a system directory is
  often a symlink itself — `/etc` is `/private/etc` on macOS — and a prefix
  that isn't resolved would never match a path that is.
  """
  @spec denied?(Path.t()) :: boolean()
  def denied?(path) do
    Enum.any?(denied(), fn prefix -> under?(path, real_path(prefix)) end)
  end

  @doc "Whether the path sits outside the project directory, worth flagging in the UI."
  @spec outside_root?(Path.t()) :: boolean()
  def outside_root?(path), do: not under?(path, root())

  @doc "Every denied prefix, absolute."
  @spec denied() :: [Path.t()]
  def denied do
    home = System.user_home() || "/root"

    @denied_absolute ++
      Enum.map(@denied_in_home, &Path.join(home, &1)) ++
      Application.get_env(:claudex_chat, :denied_paths, [])
  end

  defp under?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  @max_link_depth 32

  defp real_path(path, depth \\ 0)

  defp real_path(path, depth) when depth >= @max_link_depth, do: path

  defp real_path(path, depth) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        target |> List.to_string() |> Path.expand(Path.dirname(path)) |> real_path(depth + 1)

      {:error, _not_a_link} ->
        parent = Path.dirname(path)

        if parent == path,
          do: path,
          else: Path.join(real_path(parent, depth + 1), Path.basename(path))
    end
  end
end
