defmodule NervesSystemRG40XXV.MixProject do
  use Mix.Project

  @github_organization "kek"
  @app :nerves_system_rg40xxv
  # The repository is named after the system, so both this and artifact_sites
  # below are derived from @app rather than spelled out. A stale
  # artifact_sites entry is not loud about it: builds just look for prebuilt
  # artifacts in a repository that does not exist and fall back to building
  # from source.
  @source_url "https://github.com/#{@github_organization}/#{@app}"
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:rg40xxv_buildroot_patches, :nerves_package],
      nerves_package: nerves_package(),
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    []
  end

  # `mix precommit` is the check to run before committing, and tooling that
  # looks for such an alias will run it instead of guessing.
  #
  # It deliberately does *not* compile. Compiling this project builds the whole
  # system: `:nerves_package` is in `compilers`, so `mix compile` starts a
  # full Buildroot run in Docker whenever no cached artifact matches the
  # checksum -- which is the case after any edit to `checksum_files()`. A
  # commit-time check that triggers that is unusable, and it fails for reasons
  # unrelated to the commit.
  #
  # These two are what CI's cheap `checks` job runs that needs neither Docker
  # nor network. `tools/check-dts.sh` is left to CI: it is worth running, but it
  # downloads a kernel tree and compiles the DTS in a container.
  defp aliases do
    [
      loadconfig: [&bootstrap/1],
      precommit: [
        "format --check-formatted",
        "cmd tools/check-consistency.sh"
      ]
    ]
  end

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  def cli do
    [preferred_envs: %{docs: :docs, "hex.build": :docs, "hex.publish": :docs}]
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, "#{@github_organization}/#{@app}"}
      ],
      build_runner_opts: build_runner_opts(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      env: [
        {"TARGET_ARCH", "aarch64"},
        {"TARGET_CPU", "cortex_a53"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnu"},
        {"TARGET_GCC_FLAGS",
         "-mabi=lp64 -fstack-protector-strong -mcpu=cortex-a53 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: checksum_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.11", runtime: false},
      {:nerves_system_br, "1.34.1", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp description do
    "Nerves System - Anbernic RG40XXV handheld (Allwinner H700)"
  end

  defp docs do
    [
      # The notes and specs are extras so that links to them from the README
      # resolve. ExDoc checks such links against the generated doc set rather
      # than the filesystem, so a markdown link to a file that is not listed
      # here is reported as missing even when it exists.
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/boot-logo.md",
        "docs/display.md",
        "docs/bring-up.md",
        "docs/debugging.md",
        "docs/hacking.md",
        "docs/bluetooth-notes.md",
        "docs/dram-verification.md"
      ],
      groups_for_extras: [
        Notes: ~r"docs/[^/]+\.md"
      ],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: package_files(),
      # Every licence present in this repository, which is what Hex renders on the
      # package page. GPL-2.0-only is the kernel side, GPL-2.0-or-later the
      # Buildroot and U-Boot side; BSD-2-Clause is the board DTS's other option,
      # and the two Creative Commons entries are configuration and prose. See
      # REUSE.toml for which files are which.
      licenses: [
        "GPL-2.0-only",
        "GPL-2.0-or-later",
        "BSD-2-Clause",
        "CC0-1.0",
        "CC-BY-4.0"
      ],
      links: %{"GitHub" => @source_url}
    ]
  end

  # What ships in the Hex package: everything that goes into the image, plus the
  # prose that describes it.
  defp package_files do
    checksum_files() ++ prose_files()
  end

  # What the artifact checksum is computed from, which is a different question:
  # not "what belongs in the package" but "what could change the built image".
  #
  # Anything listed here invalidates every published artifact when it changes,
  # so a comment in nerves_defconfig costs a full rebuild -- correctly, because
  # a comment there is indistinguishable to us from a real edit.
  # Prose is distinguishable, and it is excluded below.
  defp checksum_files do
    [
      "busybox",
      "fwup_include",
      "linux",
      "rootfs_overlay",
      "uboot",
      "fwup-ops.conf",
      "fwup.conf",
      "LICENSES/*",
      "mix.exs",
      "nerves_defconfig",
      # Without this a change to a kernel patch would not alter the artifact
      # checksum, so a stale cached artifact would be reused silently.
      "patches",
      "post-build.sh",
      "post-createfs.sh",
      "REUSE.toml",
      "VERSION"
    ]
  end

  # Cannot affect a single byte of the image, so editing them must not throw
  # away a 560 MB artifact and a full CI rebuild.
  #
  # Built by addition rather than by subtracting from the package list, so that
  # renaming one of these cannot silently put it back into the checksum -- a
  # `package_files() -- ["README.md"]` would just stop matching and go quiet.
  defp prose_files do
    [
      "CHANGELOG.md",
      "README.md"
    ]
  end

  defp build_runner_opts() do
    # Download source files first to get download errors right away.
    [make_args: primary_site() ++ ["source", "all", "legal-info"]]
  end

  defp primary_site() do
    case System.get_env("BR2_PRIMARY_SITE") do
      nil -> []
      primary_site -> ["BR2_PRIMARY_SITE=#{primary_site}"]
    end
  end

  defp set_target() do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end

# Makes Buildroot carry patches/buildroot/*.patch, so that `mix compile` is the
# whole build instructions.
#
# These patch Buildroot itself rather than a package it builds, so
# BR2_GLOBAL_PATCH_DIR cannot reach them, and nerves_system_br has no hook for a
# system's own. It does apply everything in its own patches/buildroot/ when
# create-build.sh extracts the tree, and it hashes that directory into
# .nerves-br-state, so a patch placed there is applied on a fresh extraction and
# a changed one forces a clean re-extraction. Copying ours in is therefore the
# whole mechanism, and it needs no cooperation from the build runner because
# the copy happens before the runner starts.
#
# The prefix keeps the names from colliding with nerves_system_br's own 0001..,
# and sorts after them, which matters: these were written against a tree that
# already carries those.
#
# Skipping this does not fail loudly. Kconfig discards
# BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_PANFROST from nerves_defconfig when the
# mesa3d patch is missing, and the build goes on to make a Mesa with no GBM.
defmodule Mix.Tasks.Compile.Rg40xxvBuildrootPatches do
  @moduledoc false
  use Mix.Task.Compiler

  @prefix "rg40xxv-"

  @impl Mix.Task.Compiler
  def run(_args) do
    project_dir = Path.dirname(Mix.Project.project_file())
    app = Mix.Project.config()[:app]

    destination =
      Mix.Project.deps_paths()
      |> Map.fetch!(:nerves_system_br)
      |> Path.join("patches/buildroot")

    fingerprint =
      sync_patches(Path.join(project_dir, "patches/buildroot"), destination)

    discard_stale_build(
      fingerprint,
      Path.join(project_dir, ".nerves/buildroot-patches.sha256"),
      Path.wildcard(Path.join(project_dir, ".nerves/artifacts/#{app}-*")),
      Path.wildcard(Path.join(Nerves.Artifact.base_dir(), "#{app}-*"))
    )

    {:noop, []}
  end

  @doc false
  # Returns a fingerprint of the patch set.
  def sync_patches(source, destination) do
    patches =
      source
      |> Path.join("*.patch")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{@prefix <> Path.basename(&1), File.read!(&1)})

    File.mkdir_p!(destination)

    wanted = Enum.map(patches, &elem(&1, 0))

    # A patch removed or renamed here must not linger in the copy, or it would
    # keep being applied.
    destination
    |> Path.join(@prefix <> "*.patch")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in wanted))
    |> Enum.each(&File.rm!/1)

    for {name, content} <- patches do
      path = Path.join(destination, name)
      if File.read(path) != {:ok, content}, do: File.write!(path, content)
    end

    :crypto.hash(:sha256, :erlang.term_to_binary(patches)) |> Base.encode16(case: :lower)
  end

  @doc false
  # Buildroot does not rebuild a package because .config changed. A build
  # directory made under a different patch set can therefore hold packages
  # configured for options that no longer exist -- a Mesa with no GBM, in the
  # case that motivated this -- and a green build of it ships that. The
  # directory is output, reproducible from source, so it is discarded rather
  # than trusted.
  #
  # Only a *recorded* different patch set counts. With no stamp there is
  # nothing to compare against, and treating "unknown" as "stale" would throw
  # away a working build for nothing.
  def discard_stale_build(fingerprint, stamp, build_dirs, links) do
    case File.read(stamp) do
      {:ok, ^fingerprint} ->
        :ok

      {:ok, _other} when build_dirs != [] ->
        Mix.shell().info(
          "The Buildroot patches changed since the last build; discarding the old " <>
            "build directory, because Buildroot would not redo the packages it affects."
        )

        Enum.each(build_dirs, &File.rm_rf!/1)
        # A link left dangling would look like a finished build.
        links |> Enum.filter(&dangling?/1) |> Enum.each(&File.rm!/1)

      _ ->
        :ok
    end

    File.mkdir_p!(Path.dirname(stamp))
    File.write!(stamp, fingerprint)
  end

  defp dangling?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) and not File.exists?(path)
  end
end
