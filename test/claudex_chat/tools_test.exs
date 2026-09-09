defmodule ClaudexChat.ToolsTest do
  use ExUnit.Case, async: false

  alias ClaudexChat.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:claudex_chat, :default_root)
    Application.put_env(:claudex_chat, :default_root, root)

    on_exit(fn ->
      Application.put_env(:claudex_chat, :default_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "read_file/1" do
    test "returns the contents", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "hello")

      assert Tools.read_file("a.txt") == "hello"
    end

    test "refuses a denied system path" do
      assert_raise Claudex.Tool.Error, ~r/never readable or writable/, fn ->
        Tools.read_file("/etc/hosts")
      end
    end

    test "reads a file outside the project directory" do
      other = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.txt")
      File.write!(other, "elsewhere")
      on_exit(fn -> File.rm(other) end)

      assert Tools.read_file(other) == "elsewhere"
    end

    test "refuses a directory", %{root: root} do
      File.mkdir_p!(Path.join(root, "dir"))

      assert_raise Claudex.Tool.Error, ~r/is a directory/, fn -> Tools.read_file("dir") end
    end

    test "refuses a file too big to fit in the context", %{root: root} do
      File.write!(Path.join(root, "big.txt"), String.duplicate("x", 200_001))

      assert_raise Claudex.Tool.Error, ~r/over the .* byte limit/, fn ->
        Tools.read_file("big.txt")
      end
    end

    test "says so when the file isn't there" do
      assert_raise Claudex.Tool.Error, ~r/no such file/, fn -> Tools.read_file("nope.txt") end
    end
  end

  describe "write_file/2" do
    test "creates the file and any missing directories", %{root: root} do
      assert Tools.write_file("nested/deep/a.txt", "written") =~ "wrote 7 bytes"
      assert File.read!(Path.join(root, "nested/deep/a.txt")) == "written"
    end

    test "replaces what was there", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "old")
      Tools.write_file("a.txt", "new")

      assert File.read!(Path.join(root, "a.txt")) == "new"
    end

    test "refuses writing into a denied location" do
      assert_raise Claudex.Tool.Error, ~r/never readable or writable/, fn ->
        Tools.write_file("/etc/hosts", "nope")
      end
    end
  end

  describe "list_files/1" do
    test "lists entries with directories marked", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "x")
      File.mkdir_p!(Path.join(root, "sub"))

      listing = Tools.list_files(".")

      assert listing =~ "a.txt"
      assert listing =~ "sub/"
    end

    test "says so when the directory is empty", %{root: root} do
      File.mkdir_p!(Path.join(root, "empty"))

      assert Tools.list_files("empty") =~ "is empty"
    end

    test "refuses a file", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "x")

      assert_raise Claudex.Tool.Error, ~r/is a file, not a directory/, fn ->
        Tools.list_files("a.txt")
      end
    end

    test "refuses a denied system path" do
      assert_raise Claudex.Tool.Error, ~r/never readable or writable/, fn ->
        Tools.list_files("/etc")
      end
    end
  end

  describe "edit_file/3" do
    test "replaces the one occurrence", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "alpha beta gamma")

      assert Tools.edit_file("a.txt", "beta", "BETA") =~ "replaced 1 occurrence"
      assert File.read!(Path.join(root, "a.txt")) == "alpha BETA gamma"
    end

    test "refuses when the string isn't there", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "alpha")

      assert_raise Claudex.Tool.Error, ~r/does not appear/, fn ->
        Tools.edit_file("a.txt", "beta", "BETA")
      end
    end

    test "refuses an ambiguous edit rather than guessing which one", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "x = 1\ny = 1\n")

      assert_raise Claudex.Tool.Error, ~r/appears 2 times/, fn ->
        Tools.edit_file("a.txt", "= 1", "= 2")
      end

      assert File.read!(Path.join(root, "a.txt")) == "x = 1\ny = 1\n"
    end
  end
end
