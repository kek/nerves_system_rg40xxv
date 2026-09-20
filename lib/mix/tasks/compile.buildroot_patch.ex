defmodule Mix.Tasks.Compile.BuildrootPatch do
  @moduledoc """
  Installs `patches/buildroot/*` where Buildroot will be patched with them.

  `mix.exs` runs `tools/patch-buildroot.sh` from the `loadconfig` alias, which
  covers this project while it is the one being worked on. A dependency's
  aliases never run, though, so an application depending on this system would
  otherwise build without the patches -- an image with no panel firmware and no
  GPU driver, and only the first of those fails the build.

  A compiler closes that gap: Mix runs a dependency's `compilers`, so this runs
  wherever the system is built from source. It is ordered ahead of
  `:nerves_package`, the compiler that starts the Buildroot run, and has to be
  -- the patches have to be in place before `create-build.sh` extracts Buildroot
  and reads Kconfig.

  The work is in the script. This decides which nerves_system_br the build will
  use, which is not necessarily the one under this project, and turns a failure
  into a build failure.
  """
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_args) do
    root = Path.dirname(Mix.Project.project_file())
    script = Path.join(root, "tools/patch-buildroot.sh")

    if File.exists?(script) do
      case System.cmd(script, args(), cd: root, stderr_to_stdout: true) do
        {"", 0} -> :ok
        {out, 0} -> Mix.shell().info(String.trim_trailing(out))
        {out, _} -> Mix.raise("tools/patch-buildroot.sh failed:\n\n" <> out)
      end
    end

    {:noop, []}
  end

  # Nerves already knows where nerves_system_br was unpacked, and it is not
  # necessarily under this project: built as a dependency, it is a sibling in
  # the application's deps/. Ask rather than guess, but do not depend on the
  # Nerves env being bootstrapped -- the script searches both layouts when it
  # is told nothing.
  # --reconfigure-stale is safe from here and not from the loadconfig alias: a
  # compiler runs when something is being built, so rebuilding a package that
  # the patches invalidated is expected work rather than a surprise.
  defp args do
    case buildroot_package_path() do
      nil -> ["--reconfigure-stale"]
      path -> ["--reconfigure-stale", "--br-dir", path]
    end
  end

  defp buildroot_package_path do
    with nil <- System.get_env("NERVES_SYSTEM_BR_PATH") do
      nerves_env_path()
    end
  end

  # apply/3 rather than a direct call: nerves is a build-time dependency of this
  # package and the module is not always loaded when this compiles, which is a
  # warning rather than a problem since the call is guarded.
  defp nerves_env_path do
    if Code.ensure_loaded?(Nerves.Env) and function_exported?(Nerves.Env, :package, 1) do
      case apply(Nerves.Env, :package, [:nerves_system_br]) do
        %{path: path} when is_binary(path) -> path
        _ -> warn_guessing()
      end
    else
      warn_guessing()
    end
  rescue
    _ -> warn_guessing()
  end

  # Falling back to searching for the tree is right when this project is the one
  # being built, and a hazard when it is a path dependency: this project's own
  # deps/nerves_system_br exists and is the wrong tree, because Nerves builds
  # with the application's copy. Patching the wrong one puts the sentinel there
  # too, so it would look done. Say so rather than let it pass -- and note that
  # the script names the tree it patched.
  defp warn_guessing do
    Mix.shell().info([
      :yellow,
      "buildroot_patch: could not ask Nerves where nerves_system_br is; ",
      "searching instead. If this system is a path dependency, check that the ",
      "tree named below is the one the build uses.",
      :reset
    ])

    nil
  end
end
