# Changelog

## Unreleased

**The Buildroot patches apply themselves, including for consumers.**
`patches/buildroot/` patches Buildroot rather than a package it builds, so
`BR2_GLOBAL_PATCH_DIR` does not cover it and `mix deps.get` discarded both
patches with the `nerves_system_br` tree it replaced. Reapplying them was a
documented manual step, which is one `deps.get` away from a wrong build at all
times — and an application depending on this system never applied them at all.

`tools/patch-buildroot.sh` now copies them into
`nerves_system_br/patches/buildroot/`, prefixed `9` so they sort after that
package's own `0001`–`0016`. `create-build.sh` applies everything in that
directory when it extracts Buildroot, and `scripts/buildroot-state.sh` hashes it
to decide when the tree needs re-extracting, so the patches land before
`defconfig` reads Kconfig and a change to one re-extracts the tree by itself.

Installing rather than patching the extracted tree is the part that matters. On
a first build there is no tree to patch: Buildroot is downloaded, extracted,
patched and configured inside the build step, after any mix hook has run. A hook
that patches the tree therefore works only on the second build.

Two places run it. `mix.exs` calls it from the `loadconfig` alias, which every
mix task runs, covering this project. A dependency's aliases never run, so
`Mix.Tasks.Compile.BuildrootPatch` — ordered ahead of `:nerves_package` — covers
an application building this system, since Mix does run a dependency's
compilers. `lib` and `tools/patch-buildroot.sh` joined `checksum_files()`
accordingly, so they ship in the package.

Worth automating because the two patches fail differently. Losing `0002` stops
the build: the kernel cannot find `firmware/panels/*.panel` and make says so.
Losing `0001` says nothing at all — panfrost `depends on MESA3D_LLVM`, so Kconfig
drops it and takes GBM, EGL and GLES with it, and the image boots with no GPU
driver. A `kmscube` configure failure was the only reason it surfaced.

Reapplying a patch is also not sufficient by itself, which is the part that is
easy to miss. Buildroot's per-package stamps do not treat `.config` as a
dependency, so a package configured under the old answers stays stamped as done
and the stale build silently wins. Same shape as the trap in
`tools/gen-kernel-defconfig.sh`, where a Kconfig symbol that does not exist yet
is dropped without comment.

Rebuilding those packages sits behind `--reconfigure-stale`, which the compiler
passes and the `loadconfig` alias does not — the alias runs on every mix task,
and `mix format` has no business starting a Mesa rebuild. Without the flag the
script names the packages and the command instead.

**The kernel stops paying for a 115200-baud UART nobody is watching, and for
an empty games slot.** Two boot-time costs, about 3 seconds together, both
measured on the dmesg clock of a running device.

The first: every printk before fbcon comes up drains synchronously to ttyS0 —
internal test pads — at 115200 baud, about 1.5 s of it. `loglevel=5` on the
kernel command line keeps info-level chatter off the consoles while warnings
and errors still print and `dmesg` keeps everything. It is not `quiet`
because fbcon refuses to draw the boot logo at `console_loglevel <=
CONSOLE_LOGLEVEL_QUIET`, and the logo is how a working boot is told apart
from a dead panel.

The second: with no games card inserted, mmc2's pre-scan power-up runs the
controller's "update clock" command into two 750 ms timeouts (`fatal err
update clk timeout`), inside a probe that `prepare_namespace()` waits out
before mounting the root filesystem — the root mount trails mmc2's probe by
15 ms. `patches/linux/0004-mmc-sunxi-skip-prescan-power-up-when-the-slot-is-
empty.patch` sets `MMC_CAP2_NO_PRESCAN_POWERUP` when a card-detect GPIO
reports the slot empty at probe; the rescan on later insertion powers the
slot up as it always has, and a slot with a card at boot is untouched.
Compile-validated only — the empty-slot timing needs confirming on hardware.

Also: U-Boot gains `CONFIG_ZSTD`, so its squashfs driver can read a
zstd-compressed rootfs. The images are gzip today — the compressor is picked
by `mksquashfs_flags` in the application's `config :nerves, :firmware` — but
zstd unpacks several times faster on the A53s, which is Erlang VM startup
time. This ships first so flipping that flag app-side cannot produce a card
U-Boot refuses to boot.

**The power button reaches Linux, and power off now powers off.** Two separate
absences, either of which alone left the same symptom.

The button is not a GPIO — it goes to the AXP717's PWRON pin, so without
`CONFIG_INPUT_AXP20X_PEK` nothing ever learned it had been pressed.
`/proc/bus/input/devices` listed four devices and no power key. No device tree
change was needed: `axp20x.c` already registers an `axp20x-pek` cell for this
PMIC with both edge interrupts, and the driver binds it by platform device id.
The option was the only thing missing.

And `axp20x_power_off()` writes `AXP20X_OFF_CTRL` (0x32) for every variant
without its own case, a register the AXP717's map does not have at all. The
write was silently dropped, shutdown fell through to PSCI `SYSTEM_OFF`, the ATF
this board boots has no driver for the PMIC either, and the watchdog turned
every power off into a reboot.
`patches/linux/0003-mfd-axp20x-power-off-the-AXP717-via-SOFT_PWROFF.patch` sets
`SOFT_PWROFF` (0x27) bit 0 instead. Verified on the RG40XXV: the board goes
down and stays down. With a charger attached the PMIC boots it again on VBUS
presence, which is what the stock firmware does too and not this patch's doing.
The same default-case write is still in mainline as of 6.19-rc, so this is a
candidate for upstream submission rather than a backport.

> [!IMPORTANT]
> **Input event nodes renumbered.** The power key took `event0`, moving the
> gamepad to `event2`, the volume keys to `event3` and the headphone jack to
> `event4`. Anything opening a hardcoded path is now wrong; look devices up by
> name.

**The analog stick is described, for the first time.** This tree extends
mainline's `rg35xx-plus.dts`, whose board has no stick, so the one control the
two boards do not share was the one that went missing — Linux reported an
RG40XX V with fifteen keys and no `ev_abs` on any device. The stick has no ADC
of its own: it runs through a 4:1 analog multiplexer into the H700's single
GPADC channel, PI1 and PI2 selecting and PI0 enabling, so the chain is
`adc-joystick` over `io-channel-mux` over `gpio-mux` over the GPADC, and
`nerves.fragment` gains the four drivers built in. The click is described too,
as `BTN_THUMBL` on PE8, confirmed by pressing it; PE9's `BTN_THUMBR` is not,
because this shell has no second stick and a `gpio-keys` entry for a switch
that is not fitted chatters.

What is measured and what is not is worth keeping straight: the wiring is
measured, out of muOS's vendor tree for this exact device. Which two of the
four mux positions carry X and Y, and which way round each axis runs, are taken
from the two-stick sibling's left stick. All four positions are declared rather
than two, which puts every one in sysfs so that moving the stick while reading
`in_voltage[0-3]_raw` settles it. See [verifying it on a
device](docs/debugging.md#verifying-it-on-a-device).

**`vdd-dram` is Anbernic's own 1.2 V**, read off the PMIC on a booted muOS card
rather than inferred. The previous 1.1 V was an import from an LPDDR4
defconfig and not a property of this board. The wider question — that this
board is LPDDR3 and not the LPDDR4 its sibling's defconfig declares — is
settled four ways in [DRAM verification](docs/dram-verification.md).

**Nine kernel patches** are now carried in `patches/linux/`, the new ones being
the AXP717 power-off and the mmc prescan skip above.

`docs/superpowers/` was deleted and `docs/**` is now globbed as CC-BY-4.0
rather than named document by document. Its one surviving document is now
[the DE33 register map](docs/de33-register-map.md): Allwinner's undocumented
display top block, decoded from the vendor BSP and kept as reference even
though every lead in it is closed.

## v0.2.0

A minor release under semantic versioning: the boot logo is a new,
backward-compatible feature, and nothing about the board support, the partition
layout or the API surface changed. Confirmed on hardware before the bump —
panel at 2.4 s, and the four-mark strip in place of four Tuxes.

**The boot logo is the four marks this firmware actually runs**: Tux, Erlang,
Elixir and Nerves, side by side on black. The stock kernel drew four Tuxes,
because `CONFIG_LOGO` draws one copy per online CPU. There is no kernel
mechanism for four *different* images, but fbcon fits n copies where
`n*(width+8)-8 <= xres`, so a 588 px strip on a 640-wide panel is drawn exactly
once. Buildroot does the embedding natively through
`BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH`, at the cost of host-imagemagick joining
the build. See [the boot logo](docs/boot-logo.md).

**The path-referenced-content trap in [`docs/hacking.md`](docs/hacking.md) is
generalised**, because that logo option joined the family the same day and was
observed in the wild: the volume's `.config` carried the option,
host-imagemagick was built as its new dependency, and the kernel was repackaged
with the stock Tux still inside it under a fresh checksum — the logo conversion
is a pre-build hook of a `linux` package already stamped `.stamp_built`, and
Buildroot does not rebuild on config changes. The documented recipe is now
stamp deletion rather than `make linux-rebuild`, which is equivalent but keeps
the Nerves environment handling, and there is a verification command per trap.
CI never hits any of this; fresh builds have no stamps. It is purely a hazard
of the fast local loop, which is exactly when nobody is in the mood to check
what actually shipped.

## v0.1.0

First release of Nerves support for the Anbernic RG40XXV (Allwinner H700),
confirmed working on hardware.

Built on Linux 6.18.44 with the Nerves aarch64 toolchain. The board device tree
extends mainline's `sun50i-h700-anbernic-rg35xx-plus.dts`, so the AXP717 PMIC,
battery and USB power supplies, MicroSD, gamepad and volume buttons, LEDs, audio
codec, USB, RTL8821CS WiFi and Bluetooth all come from upstream.

Boot chain is SPL → ATF BL31 (`sun50i_h616`) → U-Boot 2026.04 → `sysboot`, with
A/B rootfs partitions and revert support.

**On a device:** boots, joins WiFi on 5 GHz, answers SSH over both WiFi and the
USB-C cable, drives the 4" 640×480 panel, and runs GLES2 on the Mali-G31 through
Panfrost and Mesa. Both SD slots, with ext4, vfat, exFAT and f2fs.

**The display comes up at 2.4 seconds.** The whole sun4i stack is built into the
kernel and the panel description is linked in with `CONFIG_EXTRA_FIRMWARE`, so
nothing waits for a filesystem. Getting there took two separate discoveries: one
missing device tree property — `reg = <0>` on TCON TOP's output endpoint, which
is a TCON index rather than a port number — that routed the mixer to the wrong
TCON and produced a uniform colour with no error anywhere; and a modular
`gpio-backlight` that held the built-in panel in deferred probe for seven silent
seconds. [`docs/display.md`](docs/display.md) has both in full.

Seven kernel patches in `patches/linux/`: two found during bring-up — an SDIO
reset fallback without which there is no WiFi, and a USB phy mode fix without
which the gadget never enumerates — and five for the H616 display stack. Two
Buildroot patches in `patches/buildroot/`. None are upstream as of 6.18, so all
need re-checking on a kernel bump.

Five hardware surprises had to be found the hard way, none of them visible from
source review; [`docs/bring-up.md`](docs/bring-up.md) records them, starting with
the board being LPDDR3 rather than the LPDDR4 its sibling's defconfig declares.

**Known limitations:** no HDMI, no software power-off, and `nerves_ssh` cannot
generate host keys on OTP 29 — ship them in your application's `rootfs_overlay`.

### A note on the numbering

This is the first release under a scheme where `VERSION`, the git tag and the
release all say the same thing, asserted in CI. Seven earlier tags exist in this
project's history that did not: `VERSION` stayed at `0.1.0` while the tags ran to
`v0.7.0`, and because `mix deps.get` resolves against `v$VERSION` rather than
against the tag, three of them published perfectly good artifacts onto release
pages nothing would ever read. Those tags and releases have been deleted rather
than left to mislead. CI enforces the rule by asserting that a tag matches
`VERSION`.
