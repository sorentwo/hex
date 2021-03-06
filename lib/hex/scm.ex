defmodule Hex.SCM do
  @moduledoc false

  @behaviour Mix.SCM
  @packages_dir "packages"
  @request_timeout 60_000
  @fetch_timeout @request_timeout * 2

  def fetchable? do
    true
  end

  def format(_opts) do
    "Hex package"
  end

  def format_lock(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, name, version, nil, _managers, _deps] ->
        "#{version} (#{name})"
      [:hex, name, version, <<checksum::binary-8, _::binary>>, _managers, _deps] ->
        "#{version} (#{name}) #{checksum}"
      _ ->
        nil
    end
  end

  def accepts_options(name, opts) do
    Keyword.put_new(opts, :hex, name)
  end

  def checked_out?(opts) do
    File.dir?(opts[:dest])
  end

  def lock_status(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, name, version, checksum, _managers, _deps] ->
        lock_status(opts[:dest], Atom.to_string(name), version, checksum)
      nil ->
        :mismatch
      _ ->
        :outdated
    end
  end

  defp lock_status(dest, name, version, checksum) do
    case File.read(Path.join(dest, ".hex")) do
      {:ok, file} ->
        case parse_manifest(file) do
          {^name, ^version, ^checksum, _} -> :ok
          {^name, ^version, ^checksum} -> :ok
          {^name, ^version, _} when is_nil(checksum) -> :ok
          {^name, ^version} -> :ok
          _ ->
            :mismatch
        end
      {:error, _} ->
        :mismatch
    end
  end

  def equal?(opts1, opts2) do
    opts1[:hex] == opts2[:hex]
  end

  def managers(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, _name, _version, _checksum, managers, _deps] ->
        managers || []
      _ ->
        []
    end
  end

  def checkout(opts) do
    Hex.Registry.open!(Hex.Registry.Server)

    lock = Hex.Utils.lock(opts[:lock]) |> ensure_lock(opts)
    [:hex, lock_name, version, checksum, _managers, deps] = lock

    name     = opts[:hex]
    dest     = opts[:dest]
    filename = "#{name}-#{version}.tar"
    path     = cache_path(filename)
    url      = Hex.API.repo_url("tarballs/#{filename}")

    Hex.Shell.info "  Checking package (#{url})"

    case Hex.Parallel.await(:hex_fetcher, {:tarball, name, version}, @fetch_timeout) do
      {:ok, :cached} ->
        Hex.Shell.info "  Using locally cached package"
      {:ok, :offline} ->
        Hex.Shell.info "  [OFFLINE] Using locally cached package"
      {:ok, :new, etag} ->
        Hex.Registry.tarball_etag(name, version, etag)
        if Version.compare(System.version, "1.4.0") == :lt,
          do: Hex.Registry.Server.persist
        Hex.Shell.info "  Fetched package"
      {:error, reason} ->
        Hex.Shell.error(reason)
        unless File.exists?(path) do
          Mix.raise "Package fetch failed and no cached copy available"
        end
        Hex.Shell.info "  Fetch failed. Using locally cached package"
    end

    File.rm_rf!(dest)

    meta = Hex.Tar.unpack(path, dest, {name, version})
    build_tools = guess_build_tools(meta)
    managers = build_tools |> Enum.map(&String.to_atom/1) |> Enum.sort

    manifest = encode_manifest(name, version, checksum, managers)
    File.write!(Path.join(dest, ".hex"), manifest)

    {:hex, lock_name, version, checksum, managers, Enum.sort(deps)}
  after
    Hex.Registry.pdict_clean
  end

  def update(opts) do
    checkout(opts)
  end

  @build_tools [
    {"mix.exs"     , "mix"},
    {"rebar.config", "rebar"},
    {"rebar"       , "rebar"},
    {"Makefile"    , "make"},
    {"Makefile.win", "make"}
  ]

  def guess_build_tools(%{"build_tools" => tools}) do
    if tools,
      do: Enum.uniq(tools),
      else: []
  end

  def guess_build_tools(meta) do
    base_files =
      (meta["files"] || [])
      |> Enum.filter(&(Path.dirname(&1) == "."))
      |> Enum.into(Hex.Set.new)

    Enum.flat_map(@build_tools, fn {file, tool} ->
      if file in base_files,
          do: [tool],
        else: []
    end)
    |> Enum.uniq
  end

  defp ensure_lock(nil, opts) do
    Mix.raise "The lock is missing for package #{opts[:hex]}. This could be " <>
              "because another package has configured the application name " <>
              "for the dependency incorrectly. Verify with the maintainer " <>
              "the parent application"
  end
  defp ensure_lock(lock, _opts), do: lock

  def parse_manifest(file) do
    lines =
      file
      |> String.strip
      |> String.split("\n")

    case lines do
      [first] ->
        (String.split(first, ",") ++ [[]])
        |> List.to_tuple
      [first, managers] ->
        managers = managers |> String.split(",") |> Enum.map(&String.to_atom/1)
        (String.split(first, ",") ++ [managers])
        |> List.to_tuple
    end
  end

  defp encode_manifest(name, version, checksum, managers) do
    managers = managers || []
    "#{name},#{version},#{checksum}\n#{Enum.join(managers, ",")}"
  end

  defp cache_path do
    Path.join(Hex.State.fetch!(:home), @packages_dir)
  end

  defp cache_path(name) do
    Path.join([Hex.State.fetch!(:home), @packages_dir, name])
  end

  def prefetch(lock) do
    fetch = fetch_from_lock(lock)

    Enum.each(fetch, fn {package, version} ->
      etag = Hex.Registry.tarball_etag(package, version)
      Hex.Parallel.run(:hex_fetcher, {:tarball, package, version}, fn ->
        filename = "#{package}-#{version}.tar"
        path = cache_path(filename)
        fetch(filename, path, etag)
      end)
    end)
  end

  defp fetch_from_lock(lock) do
    deps_path = Mix.Project.deps_path

    Enum.flat_map(lock, fn {app, info} ->
      case Hex.Utils.lock(info) do
        [:hex, name, version, _checksum, _managers, _deps] ->
          dest = Path.join(deps_path, "#{app}")
          case lock_status([dest: dest, lock: info]) do
            :ok       -> []
            :mismatch -> [{name, version}]
            :outdated -> [{name, version}]
          end
        _ ->
          []
      end
    end)
  end

  defp fetch(name, path, etag) do
    if Hex.State.fetch!(:offline?) do
      {:ok, :offline}
    else
      url = Hex.API.repo_url("tarballs/#{name}")
      File.mkdir_p!(cache_path())

      case Hex.Repo.request(url, etag) do
        {:ok, body, etag} ->
          File.write!(path, body)
          {:ok, :new, etag}
        other ->
          other
      end
    end
  end
end
