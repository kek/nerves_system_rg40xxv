# Buildroot patches

These patch Buildroot itself, not a package it builds, so they do not go
through `BR2_GLOBAL_PATCH_DIR`. Nothing needs doing by hand:
`tools/patch-buildroot.sh` installs them, and both `mix.exs` and
`Mix.Tasks.Compile.BuildrootPatch` run it.

```bash
tools/patch-buildroot.sh           # install or refresh
tools/patch-buildroot.sh --check   # report only; non-zero if out of sync
```

## How they get applied

Not by patching the extracted Buildroot tree. On a first build there is no tree
to patch: `create-build.sh` downloads Buildroot, extracts it, applies
`nerves_system_br`'s own patches and runs `defconfig`, all inside the build
step and all after any mix hook has had its turn. Patching after that is too
late — Kconfig has already been read, so the symbol 0002 adds is already gone
from `.config`.

Instead they are **copied into `nerves_system_br/patches/buildroot/`**, which
`create-build.sh` applies at extraction and `scripts/buildroot-state.sh` hashes
to decide when the tree needs re-extracting. Ours are prefixed `9` so they sort
after that package's `0001`–`0016`, which is required: they are written against
a tree that already has those applied.

So the patches are applied at the right moment, in the right order, and a change
to one of them re-extracts the tree on its own.

## Where it runs

`mix.exs` calls the script from the `loadconfig` alias, which every mix task
runs. That covers this project. It does not cover an application that depends on
this system, because a dependency's aliases never run — hence
`Mix.Tasks.Compile.BuildrootPatch` in `compilers`, since Mix does run a
dependency's compilers. It is ordered ahead of `:nerves_package`.

`mix deps.get` still discards the installed patches along with the
`nerves_system_br` tree. The difference is that the next mix invocation puts
them back before anything builds.

## Why this is automated rather than documented

The two patches fail differently. Losing 0002 stops the build: the kernel cannot
find `firmware/panels/*.panel`. Losing 0001 says nothing at all — panfrost
`depends on BR2_PACKAGE_MESA3D_LLVM`, so Kconfig drops it and takes GBM, EGL and
GLES with it, and the image boots with no GPU driver.

One more thing Buildroot will not do for itself: its per-package stamps do not
treat `.config` as a dependency, so a package configured before these patches
existed stays stamped as done and the stale build silently wins. Reapplying a
patch is not sufficient on its own.

Rebuilding those packages is behind `--reconfigure-stale`, which
`Mix.Tasks.Compile.BuildrootPatch` passes and the `loadconfig` alias does not.
The alias runs on every mix task, and a `mix format` that quietly starts a
forty-minute Mesa rebuild is not acceptable; a compiler only runs when something
is being built. Without the flag the script names the packages and the command.

If Buildroot moves under a patch, `apply-patches.sh` fails the build with the
patch name rather than building something wrong.

## 0001-mesa3d-panfrost-without-target-llvm

Lets the Gallium panfrost driver build without LLVM **on the target**, which
is the difference between roughly 28.5 GB of build tree and 9 GB.

Buildroot 2026.05.1 has panfrost `depends on BR2_PACKAGE_MESA3D_LLVM` and
force-selecting `NEEDS_PRECOMP_COMPILER`, which selects `MESA3D_OPENCL`, which
in turn depends on `MESA3D_LLVM` and selects target `CLANG` and `LIBCLC`. So
asking for panfrost asks for LLVM and clang cross-compiled for the device.

Mesa does not need any of that at runtime. It needs a *compiler* to precompile
shaders at build time, and `mesa3d.mk` already builds one for the host:

    HOST_MESA3D_CONF_OPTS = ... -Dmesa-clc=enabled -Dprecomp-compiler=enabled
    MESA3D_CONF_OPTS += -Dmesa-clc=system -Dprecomp-compiler=system

`system` means the target build consumes the host's `mesa-clc` and
precompiler. The target LLVM is redundant.

Verified: with this patch, `libEGL.so`, `libGLESv2.so` and the panfrost DRI
driver build and install into staging. Host-side LLVM and clang are still
built -- they are what the precompiler needs -- but those are ~6 GB rather
than an additional ~20 GB on the target.

Three things had to change together, and the third is the one that is easy to
miss:

1. Drop `depends on BR2_PACKAGE_MESA3D_LLVM` from the panfrost driver.
2. Drop `select BR2_PACKAGE_MESA3D_OPENCL` and
   `select BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR` from
   `BR2_PACKAGE_MESA3D_NEEDS_PRECOMP_COMPILER`.
3. Drop `spirv-llvm-translator` from `MESA3D_DEPENDENCIES`. This one is a
   *make* dependency, not a Kconfig select, so removing the select is not
   enough -- Buildroot still queues the target package, which drags target
   LLVM back in. Symptom: the build starts configuring `build/llvm-22.1.7`
   even though `BR2_PACKAGE_LLVM` is absent from `.config`.

Also needed: `-Dcpp_rtti=false` for host-mesa3d. `MESA3D_OPENCL` used to
`select BR2_PACKAGE_LLVM_RTTI`, which built host LLVM with RTTI on. Without
it, host-mesa3d's configure fails with

    LLVM was built without RTTI, so Mesa must also disable RTTI.
    Use an LLVM built with LLVM_ENABLE_RTTI or add cpp_rtti=false.

`BR2_PACKAGE_LLVM_RTTI` lives inside `if BR2_PACKAGE_LLVM`, so it cannot be
set from the defconfig without pulling target LLVM back in -- hence disabling
RTTI on the Mesa side instead.

### Disk, and a trap that looks like a disk problem

This fits in a 63 GB Docker Desktop VM, but only after one piece of cleanup
that is easy to mistake for needing a bigger disk.

The artifact step copies the sysroot and tars it, so a bloated sysroot is paid
for twice. An *aborted* target-LLVM build leaves its staging install behind:
1.86 GB of `libLLVM.so.22.1` plus several hundred `libLLVM*.a`, which took the
sysroot from ~1.2 GB to 10 GB. Nothing depends on those files once the patch
is applied, and Buildroot never removes them, so every subsequent packaging
attempt failed with "No space left on device" while the real fault was
orphaned files. Removing them from
`host/aarch64-buildroot-linux-gnu/sysroot/usr/lib` fixed it.

If you hit disk errors during the artifact step, measure the sysroot before
concluding the VM is too small.
