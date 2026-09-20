# What bring-up actually found

Five things, none of which were visible from source review. The display was a
sixth and has [its own document](display.md).

## 1. This unit is LPDDR3, not LPDDR4

This is the important one. `configs/anbernic_rg35xx_h700_defconfig` upstream
specifies `CONFIG_SUNXI_DRAM_H616_LPDDR4`, and this system copied it verbatim
on the premise that the H700 Anbernics share a PCB family. They do not share
memory. With LPDDR4 timings the SPL hangs in DRAM init and the SoC stops
responding entirely — no console, no LED, indistinguishable from a dead device.

The correct values came from the **vendor boot0 on a muOS card** that boots
this hardware. Its `dram_para` struct at offset `0x38` declares
`dram_type = 7` (LPDDR3) and carries different drive-strength and ODT values,
while agreeing with upstream on the 672 MHz clock — which is what confirmed the
struct offset had been read correctly:

```bash
sudo dd if=/dev/rdiskN bs=512 skip=16 count=256 of=boot0.bin
tools/dram-type.sh boot0 boot0.bin
```

Everything since done to that claim — verifying it on the hardware four
independent ways, correcting an "LPDDR4 family" label that turns out to be
secondhand everywhere it appears, and one open question about the DRAM rail
voltage that matters more than the type ever did — lives in
**[dram-verification.md](dram-verification.md)**. One result from there changes
how this section should be read: the finding is about **this unit**, not the
model. ROCKNIX ships both an LPDDR3 and an LPDDR4 U-Boot for the H700 and
chooses between them per unit by reading a regulator, so model identity does
not predict the memory type.

If you ever doubt an inherited hardware parameter, that is the technique: a
firmware known to boot the hardware is ground truth in a way a sibling board's
defconfig is not. See the comment in `uboot/uboot.defconfig`, which also
records that the TPR field ordering is *inferred* rather than confirmed against
a struct definition — the one part of this nothing has settled.

## 2. `pwrseq_simple` aborts instead of using its own GPIO fallback

On 6.18 it demands a reset controller whenever a node has exactly one
`reset-gpios` entry, and returns early when it cannot get one, skipping the
GPIO path directly below it. Our WiFi node has `reset-gpios` and no `resets`,
so mmc1 never initialised and `wlan0` never existed. Fixed by
`patches/linux/0001-mmc-pwrseq_simple-gpio-reset-fallback.patch`.

## 3. `CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES` were missing

vintage_net gives each interface its own routing table, so without them
`VintageNet.RouteManager` crashes moments after DHCP succeeds. The symptom is
WiFi that associates, obtains a lease, deauthenticates "by local choice", and
loops — present and configured but never reachable.

## 4. The LED is a charge indicator, not a boot signal

It is tempting to build an LED-based triage tree on the reasoning that
`CONFIG_SPL_SUNXI_LED_STATUS_GPIO=268` (PI12) is the power LED, so the SPL
lights it before Linux. The reasoning is sound but the conclusion is not: on
real hardware the LED glows a steady yellow whenever the device has power,
because it is the AXP717's charge indicator, so it looks identical whether the
device booted or is wedged.

**Do not read anything into the LED at power-on.**

An application can create a real signal by pointing a LED at the kernel's
heartbeat trigger, which is worth doing — a blinking LED then means kernel up,
BEAM up, application supervision tree up:

```elixir
File.write("/sys/class/leds/green:status/trigger", "heartbeat")
```

`/sys/class/leds` has `green:power`, `green:status`, `rgb:indicator` and
`rtw88-mmc1:0001:1`. This needs no kernel changes; `CONFIG_LEDS_GPIO` and
`CONFIG_LEDS_TRIGGER_HEARTBEAT` are already built in.

## 5. The OTG phy is shared, and the host driver was winning it

`sun50i_h616_cfg` sets `.phy0_dual_route = true`, so the EHCI/OHCI host
controllers and MUSB share phy0 and both call `phy_set_mode()` on it. The host
won, leaving the type-C port electrically in host mode — logged as
`phy-5100400.phy.0: Changing dr_mode to 1` — while the gadget composed happily
and was assigned an address that could never carry traffic. Fixed by
`patches/linux/0002-phy-sun4i-usb-let-the-mux-route-decide-phy0-mode.patch`.

The wrong theory here is worth recording: the board DTS notes that the AXP717's
type-C role switch has no device tree binding, and that was taken as the likely
cause. It was a plausible reading of a real comment, and it was wrong. The
missing binding was not the problem; two drivers contending for one phy was.

## How this was verified

On-device boot **is** confirmed. What follows is the build-time verification
reached *before* any hardware was available. It is kept because CI still
enforces all of it on every change, and because the gap between it and reality
turned out to be the instructive part.

**The system builds.** A full Buildroot build completes and produces
`bl31.bin`, `Image`, `sun50i-h700-anbernic-rg40xx-v.dtb`,
`u-boot-sunxi-with-spl.bin`, `uboot-env.bin`, and `rootfs.squashfs`. ATF
built for `PLAT=sun50i_h616` and its BL31 was folded into U-Boot, so the
bootloader chain is wired up rather than merely configured.

**The device tree is what it claims to be.** The DTB *as built by
Buildroot inside the real kernel tree* was decompiled and checked: model
`Anbernic RG40XX V`, compatible `anbernic,rg40xx-v`, the `led-rgb` node
merged into mainline's unlabelled `leds` node, the RTL8821CS `wifi@1` node
inherited, and 17 button nodes. It also checks the whole display pipeline —
display engine, DE33 bus and clocks, mixer, TCON TOP, TCON LCD, panel, its
generic fallback, the bit-banged SPI command channel, the backlight and the
RGB888 pinmux — and asserts the mixer uses upstream's three-window binding
with no ROCKNIX `planes@` node, since that combination probes cleanly and
still gives a dark screen. `tools/check-dts.sh` reruns this standalone
against a fresh kernel tree.

**The kernel has the drivers.** Every symbol `linux/nerves.fragment` asks
for survives `olddefconfig`, and the boot-critical driver list is asserted
present — plus an assertion that no initramfs is configured, since
`erlinit` must be PID 1 straight out of the squashfs.
`tools/gen-kernel-defconfig.sh` fails if any of that regresses.

**A real firmware image is produced and lands correctly on disk.**
`mix firmware` against this system produces a `.fw`
(`meta-platform=rg40xxv`, `meta-architecture=aarch64`). Applying its
`complete` task to a disk image and inspecting the result confirms:

- `eGON.BT0` at byte 8192, so the Allwinner BROM will find the SPL
- partitions at LBA 43008 / 829440 / 1615872 — i.e. `mmcblk0p2`, `p3`,
  `p4`, matching what `extlinux.conf` and `erlinit.config` expect
- rootfs A is a valid squashfs, gzip-compressed, which is the one
  compression U-Boot can actually read here
- the U-Boot environment at `0x400000` carries `nerves_fw_active=a`,
  `a.nerves_fw_platform=rg40xxv`, and the A/B `bootcmd`
- `/boot/Image`, `/boot/sun50i-h700-anbernic-rg40xx-v.dtb`, and both
  `extlinux` configs are present inside the rootfs

**The layout is self-consistent.** `tools/check-consistency.sh` asserts the
partition offsets, `CONFIG_ENV_OFFSET`, `fw_env.config`, each `root=`, and
erlinit's mount all agree. `mix nerves.system.lint` reports no failed
checks; it advises adding `e2fsprogs`, which this system deliberately omits
because the application partition is f2fs and `f2fs-tools` is what
`nerves_runtime` needs to reformat it.

**What all of that missed is the useful part.** Every artifact above was
well-formed and internally consistent, and none of those checks predicted any
of the things that actually stopped the board — a DRAM type, a driver's
early-return, two absent kernel symbols, the colour of a LED, and one missing
device tree property. Well-formed is not the same as correct, and the distance
between them is the size of the hardware you do not have.

The "matches its siblings" premise held for the PMIC, mmc0, the gamepad and
WiFi, and broke for DRAM. Of the inherited assumptions, the button GPIO mapping
is the one still unexercised.
