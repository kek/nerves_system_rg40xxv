# Hacking on the system

You only need any of this if you are changing the BSP rather than using it.

```bash
git clone https://github.com/kek/nerves_system_rg40xxv
cd nerves_system_rg40xxv
mix deps.get
mix compile          # builds via Docker on macOS, natively on Linux
```

A full build is between one and three and a half hours depending on how much
`ccache` survives, and needs roughly 25 GB free.

`mix precommit` is the check to run before committing: `mix format --check` and
`tools/check-consistency.sh`. It deliberately does *not* compile, because
`:nerves_package` is in `compilers` and `mix compile` starts a Buildroot run
whenever no cached artifact matches the checksum.

## Almost every edit invalidates the artifact

`checksum_files()` in `mix.exs` determines the artifact checksum — not
`package_files()`, which is the longer list of what gets published. The two were
split precisely so that prose could be edited for free: `README.md` and
`CHANGELOG.md` are published but excluded from the checksum, and `docs/` is in
neither, which is why the long-form notes live there.

Ask the gate rather than guessing, since the answer decides whether a
three-and-a-half-hour build runs:

```bash
printf 'docs/hacking.md\n' | .github/scripts/build-needed.sh mix.exs   # false
printf 'REUSE.toml\n'       | .github/scripts/build-needed.sh mix.exs   # true
```

### The licensing corner of this

`REUSE.toml` *is* in `checksum_files()`, and CI runs `reuse lint`, which needs
every file in the repository to carry copyright and licence information —
whether or not it ships. Those two facts would collide if each document were
enumerated by name: adding a document under `docs/` costs nothing, but an edit
to `REUSE.toml` costs a full rebuild for one annotation.

So `REUSE.toml` globs `docs/**` as CC-BY-4.0, and **a new document is licensed
the moment it is created** with no edit here. Add prose freely. The glob is
safe only while everything under `docs/` really is CC-BY-4.0: a subdirectory
under a different licence would be silently relicensed by it, and would force
the documents back to being enumerated by name.

Worth being clear about what is and is not required, since it is easy to
overestimate. Nothing about the licence is needed for distribution — `docs/` is
in neither the artifact nor the published package. It is needed to keep a REUSE
compliance claim the project chose to make and gates on, and REUSE is
all-or-nothing: there is no partial pass, so one unlicensed file drops the claim
for the whole repository.

## Regenerating the kernel configuration

After editing `linux/nerves.fragment`:

```bash
tools/gen-kernel-defconfig.sh 6.18.44
```

This runs in Docker, asserts that every symbol you asked for actually took
effect, checks the boot-critical driver list, and writes
`linux/linux-6.18.defconfig`. It exits non-zero if anything is missing, so
it is safe to run in CI.

Asserting that symbols *took effect* is not pedantry. Kconfig silently
downgrades a `=y` symbol whose subsystem is `=m` rather than reporting a
conflict, which is exactly how `CONFIG_DRM_PANEL_MIPI=y` turned into a module
that nothing loads. Some symbols are also enabled by the arm64 defconfig and
omitted by `savedefconfig` because they default on — those are checked against
the full `.config` instead.

## Path-referenced content does not trigger rebuilds

> [!WARNING]
> **`mix compile` after editing path-referenced content ships the *previous*
> bytes under a *fresh* checksum.** This has put a wrong device tree on
> hardware once and a stale boot logo on hardware once.

Several Buildroot options name a file by path and consume its contents during
a package's build. Buildroot depends on nothing about these files — not the
path, not the mtime, not the content — because it deliberately does not track
configuration changes at all. If the consuming package is already stamped
`.stamp_built`, the option is silently inert:

- `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` — an edited DTS is not re-copied, and
  `images/*.dtb` keeps its old content.
- `BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH` — the logo conversion is a *pre-build
  hook* of the linux package, so with the kernel stamped built the hook never
  runs. Observed in practice: the volume's `.config` carried the new option,
  `host-imagemagick` was even built as the new dependency, and the kernel was
  repackaged with the stock Tux inside. Only kernel *config* files are
  genuinely content-tracked by `linux.mk`, which is why a `nerves.fragment`
  edit does rebuild the kernel while these do not.
- `uboot/uboot.env` — the original instance of the shape.

It is worse than it sounds, because the artifact checksum *does* change (the
DTS is under `linux/`, which is in `package_files()`). So the build looks like
it did the right thing: a new checksum, a new artifact, a new firmware UUID —
carrying a stale DTB.

There is a second half. Once the kernel is rebuilt in the Docker volume, the
*installed* artifact is still stale, and `mix compile` will not refresh it,
because the source checksum has not changed since the bad build. Both halves
have to be broken:

```bash
# 1. Force the linux package to rebuild -- its pre-build hooks (logo convert,
#    DTS copy) run again. Deleting the stamps and letting mix redo the make
#    is equivalent to `make linux-rebuild` and keeps the environment right:
docker run --rm --mount type=volume,src=nerves_system_rg40xxv-<id>,target=/v \
  ghcr.io/nerves-project/nerves_system_br:1.34.1 \
  rm -f /v/build/linux-*/.stamp_built \
        /v/build/linux-*/.stamp_target_installed \
        /v/build/linux-*/.stamp_images_installed \
        /v/build/linux-*/.stamp_staging_installed

# 2. Force the artifact to be reinstalled from the volume
rm -rf ~/.nerves/artifacts/nerves_system_rg40xxv-portable-0.1.0
mix compile
```

Then check what actually shipped, rather than trusting the build:

```bash
# the DTS trap:
dtc -I dtb -O dts ~/.nerves/artifacts/nerves_system_rg40xxv-portable-0.1.0/images/*.dtb \
  | grep -o 'anbernic,rg40xx[a-z0-9-]*panel'

# the logo trap -- must print the strip's dimensions, not "80 80". Grep for
# the dimensions line rather than head -3: ImageMagick preserves the stock
# file's comment, so the first lines still read "Standard 224-color Linux
# logo" even when the pixels are the strip's.
docker run --rm -v nerves_system_rg40xxv-<id>:/v ghcr.io/nerves-project/nerves_system_br:1.34.1 \
  grep -m1 -E '^[0-9]+ [0-9]+$' /v/build/linux-*/drivers/video/logo/logo_linux_clut224.ppm
```

CI never hits any of this: a fresh build has no stamps, so every hook runs.
The trap exists only for incremental local builds in an existing volume --
which is exactly the mode used to iterate quickly, so it will be hit again.

`make linux-dirclean` and a full rebuild is the heavier, always-correct
version.

## Patches

`patches/linux/` carries nine patches and `patches/buildroot/` carries two;
each has a header explaining its upstream status, and
[`patches/buildroot/README.md`](../patches/buildroot/README.md) explains the
Buildroot ones in full. None are upstream as of 6.18, so all need re-checking
on a kernel bump.

## Notes on the boot chain

```
BROM → SPL → ATF BL31 (sun50i_h616) → U-Boot → sysboot → Linux
```

Two things here are easy to get wrong:

- **The kernel device tree is named explicitly** in
  `rootfs_overlay/boot/extlinux/extlinux-{a,b}.conf`. U-Boot's own built-in
  DTB is `sun50i-h700-anbernic-rg35xx-2024`, which leaves `mmc1` disabled.
  Booting on it produces a board with no WiFi and the wrong model string,
  and nothing obviously fails — so do not remove the `fdt` line.
- **Firmware updates do not rewrite the bootloader.** SPL and U-Boot are
  written only by the `complete` task, because they are not A/B redundant
  and an interrupted in-place rewrite would brick the device. If a system
  update changes U-Boot or the environment layout, re-flash the card rather
  than running `mix upload` / `mix firmware.burn --task upgrade`.
