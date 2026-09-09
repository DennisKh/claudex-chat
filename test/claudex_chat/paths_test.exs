defmodule ClaudexChat.PathsTest do
  @moduledoc """
  The deny list is the one boundary approval cannot lift, so the refusals here
  are the point of the file.
  """

  use ExUnit.Case, async: false

  alias ClaudexChat.Paths

  setup do
    root = Path.join(System.tmp_dir!(), "paths-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))
    previous = Application.get_env(:claudex_chat, :default_root)
    Application.put_env(:claudex_chat, :default_root, root)

    on_exit(fn ->
      Application.put_env(:claudex_chat, :default_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "reachable paths" do
    test "a relative path resolves against the root" do
      assert {:ok, path} = Paths.resolve("sub/file.txt")
      assert String.ends_with?(path, "/sub/file.txt")
    end

    test "a path that doesn't exist yet is allowed, so a file can be created" do
      assert {:ok, _path} = Paths.resolve("new/nested/file.txt")
    end

    test "another project outside the root is reachable" do
      assert {:ok, _path} = Paths.resolve(Path.join(System.tmp_dir!(), "other-project/mix.exs"))
    end

    test "walking out of the root with .. is reachable" do
      assert {:ok, _path} = Paths.resolve("../elsewhere.txt")
    end

    test "a home directory like Downloads is reachable" do
      assert {:ok, _path} = Paths.resolve(Path.join(System.user_home!(), "Downloads/report.pdf"))
    end
  end

  describe "denied paths" do
    test "system directories" do
      for path <- ~w(/etc/hosts /usr/bin/ls /bin/sh /System/Library/x /private/etc/passwd) do
        assert {:error, :denied} = Paths.resolve(path), "expected #{path} to be denied"
      end
    end

    test "credential stores in the home directory" do
      home = System.user_home!()

      for relative <- ~w(.ssh/id_rsa .aws/credentials .gnupg/secring.gpg .config/anthropic/key) do
        path = Path.join(home, relative)
        assert {:error, :denied} = Paths.resolve(path), "expected #{path} to be denied"
      end
    end

    test "a symlink pointing into a denied directory", %{root: root} do
      link = Path.join(root, "sneaky")
      File.ln_s!("/etc", link)

      assert {:error, :denied} = Paths.resolve("sneaky/hosts")
    end

    test "extra denials from config" do
      previous = Application.get_env(:claudex_chat, :denied_paths, [])
      secret = Path.join(System.tmp_dir!(), "company-secrets")
      Application.put_env(:claudex_chat, :denied_paths, [secret])
      on_exit(fn -> Application.put_env(:claudex_chat, :denied_paths, previous) end)

      assert {:error, :denied} = Paths.resolve(Path.join(secret, "keys.txt"))
    end
  end

  describe "outside_root?/1" do
    test "flags a path the UI should mark", %{root: root} do
      refute Paths.outside_root?(Path.join(root, "sub/file.txt"))
      assert Paths.outside_root?("/tmp/somewhere-else.txt")
    end
  end
end
