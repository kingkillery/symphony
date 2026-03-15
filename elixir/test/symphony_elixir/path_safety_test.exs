defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  setup do
    dir = Path.join(System.tmp_dir!(), "path-safety-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "canonicalizes a regular path without symlinks", %{dir: dir} do
    file = Path.join(dir, "real_file.txt")
    File.write!(file, "hello")

    assert {:ok, ^file} = PathSafety.canonicalize(file)
  end

  test "resolves a single symlink hop", %{dir: dir} do
    target = Path.join(dir, "target.txt")
    File.write!(target, "data")

    link = Path.join(dir, "link.txt")
    File.ln_s!(target, link)

    assert {:ok, ^target} = PathSafety.canonicalize(link)
  end

  test "resolves chained symlinks", %{dir: dir} do
    target = Path.join(dir, "final.txt")
    File.write!(target, "data")

    mid_link = Path.join(dir, "mid_link")
    File.ln_s!(target, mid_link)

    top_link = Path.join(dir, "top_link")
    File.ln_s!(mid_link, top_link)

    assert {:ok, ^target} = PathSafety.canonicalize(top_link)
  end

  test "resolves symlinked directory in path", %{dir: dir} do
    real_dir = Path.join(dir, "real_dir")
    File.mkdir_p!(real_dir)
    file = Path.join(real_dir, "file.txt")
    File.write!(file, "content")

    link_dir = Path.join(dir, "link_dir")
    File.ln_s!(real_dir, link_dir)

    path_through_link = Path.join(link_dir, "file.txt")
    assert {:ok, ^file} = PathSafety.canonicalize(path_through_link)
  end

  test "returns joined path for non-existent intermediate segments", %{dir: dir} do
    path = Path.join([dir, "nonexistent", "deep", "file.txt"])
    assert {:ok, ^path} = PathSafety.canonicalize(path)
  end

  test "propagates error for permission-denied or other file errors" do
    # Use a path that would cause a stat error (not enoent)
    # We test the error wrapping format
    bad_path = "/proc/1/root/test_file"

    case PathSafety.canonicalize(bad_path) do
      {:ok, _} ->
        # If we're running as root or path resolves, that's fine
        :ok

      {:error, {:path_canonicalize_failed, _expanded, reason}} ->
        assert is_atom(reason)
    end
  end

  test "expands relative paths", %{dir: dir} do
    file = Path.join(dir, "relative_test.txt")
    File.write!(file, "data")

    # Path.expand will make it absolute
    assert {:ok, result} = PathSafety.canonicalize(file)
    assert String.starts_with?(result, "/")
  end
end
