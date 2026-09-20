# The display, and what is actually known about it

The 4" LCD **works, confirmed on hardware**: the panel shows the framebuffer
console. Everything below distinguishes what is measured from what is not,
because on this board "no picture" covers at least four unrelated failures and
the screen is the thing under test.

## The one-register bug that cost weeks

It spent a long time showing a uniform colour that ignored the framebuffer,
with every register anyone thought to compare reading correctly. The cause was
one missing device tree property, and it is worth stating up front because the
failure had no error attached to it anywhere:

**The endpoint in TCON TOP's output port must carry `reg = <0>`, and that value
is a TCON index rather than a port number.** `sun4i_tcon_of_get_id_from_port()`
reads it with `of_property_read_u32()` and has no default, so omitting it
returns `-EINVAL` — and nothing checks the sign. `sun8i_tcon_top_de_config()`
only rejects `tcon > 3`, so `-22` reached
`FIELD_PREP(TCON_TOP_PORT_DE0_MSK, ...)`, whose two-bit mask turned it into 2.
`TCON_TOP_PORT_SEL` then routed mixer0 to TCON2 while the panel hangs off
TCON0. The panel got a constant colour, the display engine never completed a
frame, and nothing logged a word about it.

Two details made it hard to see. The mixer derives its own id from the same
graph but through `of_graph_parse_endpoint()`, which *does* default a missing
`reg` to 0 — so one half of the pipeline tolerated the omission and the other
half did not. And `patches/linux/0103` writes the correct `0x20` into
`PORT_SEL` at bind, which looked like it had the routing covered; the TCON
driver overwrites the DE0 field afterwards.

`tools/check-dts.sh` now asserts the property, because it produces no error and
no log line when it is wrong.

## What is measured, on hardware

- **The framebuffer console is visible on the panel.**
- `TCON_TOP_PORT_SEL` (`0x651001c`) reads `0x20`, matching a muOS that drives
  this panel correctly. It read `0x22` while the screen was blank.
- The mixer's global status (`0x1008104`) reads `0x111`, again matching muOS.
  **Bit 0 is the frame-end latch**, and it re-arms after each write-1-to-clear,
  so the display engine is completing frames. It read `0x100` — bit 0 never
  set — for as long as the routing was wrong.
- `/sys/class/drm/card0` and `card0-DSI-1` exist; `/dev/fb0` exists.
- Connector `connected`, `enabled`, DPMS `On`, mode 640×480, physical size
  81×61 mm (read out of the panel blob).
- dmesg: blob `loaded successfully`; all three components bound (`mixer`,
  `tcon-top`, `lcd-controller`); `[drm] Initialized sun4i-drm`;
  `Console: switching to colour frame buffer device 80x30`.
- Clock tree: `tcon-lcd0` enabled at 81 MHz with **`tcon-data-clock` at
  27 MHz** — the TCON really is clocking pixels out.
- `vdd-lcd` (the PI15 rail) and `vcc-io` (bank D) both enabled; **backlight
  physically lit**, so `gpio-backlight` on PD28 and active-high are both right.
- DRM atomic state: `plane-1` attached to `crtc-0` with fbcon's `XR24`
  640×480 buffer, pitch 2560. No errors anywhere in dmesg — no SPI warnings,
  no DRM warnings.

## How it was found, and what that ruled out along the way

Worth keeping, because the wrong answers were expensive and each looked
convincing.

Writing solid red into `/dev/fb0` did not change what the panel showed, which
established three things: the SPI command channel works (the v1 blob gave a
blank screen and v2 a uniform colour, so panel behaviour tracked the init
sequence, and the pin *roles* are right); the panel and DRM are both innocent,
since every software-visible layer was correct; and therefore the fault sat in
the DE→TCON path, below what DRM can see.

That is where it stayed for a while, because **upstream's DE33 mixer was the
obvious suspect and it was the wrong one**. Mainline has the DE33 mixer and
clock drivers but no H616 display device tree at all, so that path has never
been exercised by an upstream board; ROCKNIX carries a newer refactor splitting
plane handling into a separate `sun50i_planes` driver, and ROCKNIX has the field
evidence. Adopting it was the recommended next step for some time. Two
measurements killed that theory: the plane-mapping constants upstream admits it
does not understand turned out to match muOS exactly, and then every register in
the mixer — layer enable, format, pitch, `TOP_LADDR` pointing at a real
framebuffer, blender route, sizes — read correctly while the engine still did
nothing.

Decoding Allwinner's own sun50iw9 BSP is what converted "the screen is green"
into a one-register boolean; that decode is [the DE33 register
map](de33-register-map.md). Once `0x1008104` was known to be the frame-end
latch, the question became "why does this engine never finish a frame" — and an
engine wired to a TCON that is not driving the panel never will.

The general lesson is the one this board keeps teaching: **a firmware known to
drive the hardware is ground truth in a way source review is not.** Comparing
one register against muOS answered in minutes what weeks of reading upstream
source had not.

The pipeline is:

```
mixer0 -> tcon_top -> tcon_lcd0 -> panel   (RGB888 pixels + SPI init sequence)
```

Verified in the build: the patch series applies cleanly to 6.18.44 in the real
Buildroot flow; the kernel builds; the DTB compiles and passes every pipeline
assertion in `tools/check-dts.sh`; and both panel blobs are installed in the
target rootfs.

Two `dtc` warnings are expected, and `tools/check-dts-inner.sh` says which:
`unit_address_vs_reg` on `/soc` comes from mainline's dtsi, and
`graph_child_address` on tcon-top's `port@1` is ours and deliberate — see the
note in the DTS.

## Five patches, not ROCKNIX's twenty-three

ROCKNIX carries roughly 23 kernel patches for this display; this tree needs
five, because **6.18.44 already carries the H616 DE33 mixer and its clocks** —
`allwinner,sun50i-h616-de33-mixer-0` and `-de33-clk` are upstream, and
`sun8i-mixer` is built regardless. What is genuinely missing upstream is the
TCON support, the panel driver, and the device tree.

The five patches are `patches/linux/0100`–`0104`. Each has a header explaining
its upstream status.

ROCKNIX also carries a *newer* refactor that moves plane handling out of the
mixer into a separate `sun50i_planes` driver. That is deliberately **not**
taken: 6.18.44 implements DE33 planes inside the mixer, and adopting ROCKNIX's
version would mean reverting working upstream code. The visible consequence is
in the device tree — the mixer node uses upstream's binding,
`reg-names = "layers", "top", "display"`, and must *not* have a separate
`planes@` node. Both are asserted by `tools/check-dts.sh`, because getting it
wrong yields a mixer that probes and a screen that stays dark.

## The panel description is a firmware blob

The generic panel driver carries no panel data. It builds a filename from the
panel node's first `compatible` string and reads **both the timings and the
controller init sequence** out of `panels/<compatible>.panel`. There is no
`panel-timing` node anywhere; do not look for one.

A correct kernel and a correct device tree, without that blob, give **no
picture and no error**.

The blob is *linked into the kernel image* via `CONFIG_EXTRA_FIRMWARE`, and the
whole sun4i stack is built in with it. That is a deliberate change from the
arrangement that first produced a picture, where the panel driver was a module
loaded by `erlinit`'s `--pre-run-exec` after `/root` was mounted:

- A built-in panel driver probes before any filesystem exists, so
  `request_firmware()` cannot reach `/lib/firmware`. There is no initramfs here
  by design — `erlinit` is PID 1 straight out of the squashfs. That is why the
  first built-in attempt failed with `-2`.
- `CONFIG_EXTRA_FIRMWARE` answers precisely that: the blob is satisfied from
  the kernel's built-in table with no filesystem involved.
  `patches/buildroot/0002` copies it into the kernel tree from
  `BR2_LINUX_KERNEL_EXTRA_FIRMWARE_DIR`, which points at the same
  `rootfs_overlay` directory that installs it to `/lib/firmware` — one copy of
  the file, used twice.
- It has to be the *whole* stack, not just the panel. The arm64 defconfig
  leaves `CONFIG_DRM=m`, and Kconfig silently downgrades a `=y` symbol whose
  subsystem is `=m` rather than complaining. Setting only
  `CONFIG_DRM_PANEL_MIPI=y` produced a generated defconfig still saying `=m` —
  which would have built a module that nothing loads, because this panel
  cannot autoload: the SPI core derives the modalias from the panel's first
  compatible string (`spi:rg40xx-v2-panel`) while the driver advertises
  `panel-mipi-dpi-spi`.

The motive is boot time. Measured on the module arrangement:

```
2.32s   init starts
2.78s   f2fs starts mounting /root
5.73s   /root mounted
7.10s   the BEAM starts
9.47s   panel-mipi binds
10.27s  console switches to the framebuffer
```

The panel waited about three seconds behind an f2fs mount that has nothing to
do with it, and the BEAM was running two and a half seconds before the panel
existed. Building it in should move first light to roughly two seconds.

> [!NOTE]
> **Confirmed on hardware.** The console switches to the framebuffer at about
> 2.4 s, against 10.27 s on the module arrangement above, so building the
> stack in did what the numbers predicted.

`tools/check-consistency.sh` asserts that the spelling in the DTS matches a
file that exists and that `CONFIG_EXTRA_FIRMWARE` names that same panel, since
nothing checks it at build time.

## Which panel this unit has

**`anbernic,rg40xx-v2-panel`. Settled by testing both, on working hardware.**

With the display otherwise healthy — connector `connected`, frame-end latch
running, the correct blob confirmed loaded in dmesg — the panel is the only
variable left, so swapping the one string is a clean experiment:

| `compatible` | Result |
|---|---|
| `anbernic,rg40xx-v2-panel` | Correct, readable image |
| `anbernic,rg40xx-panel` (v1) | **Blank, backlight on** |

So this unit is ROCKNIX's **v2** panel.

That is worth stating loudly because **muOS names this hardware's panel
`fog_fj035fhd05_v1`**, and the obvious reading — that the vendor's `_v1` is
ROCKNIX's non-`-v2` variant — is now measured to be **wrong**. The two naming
schemes do not describe the same split. The vendor suffix is not evidence about
which ROCKNIX blob to use, and the earlier recommendation in the panel spec to
"start with `anbernic,rg40xx-panel`" was a reasonable inference that the
hardware contradicts.

Both earlier attempts at this question were made while the mixer was routed to
the wrong TCON, so neither could have shown anything; that is why this was
unresolved for so long rather than because the evidence was subtle.

Two traps when reading the log here:

- Both variants report 640×480 @ 60 Hz with identical active area, so **a
  correct mode confirms nothing about the variant.** What differs is the init
  sequence (v2 731 bytes against v1 537), the sync polarity (v2 `0x5` =
  PHSYNC|PVSYNC against v1 `0x0a` = NHSYNC|NVSYNC, which DRM reports as
  `bus_flags` `0x00000046` and `0x0000000a`) and the reset/init delays (v2
  5 ms / 20 ms against v1 1 ms / 10 ms).
- The v1 blob adds a second mode, 640×480 @ 120 Hz, and v2 does not. Two
  modelines in dmesg therefore tells you which **file** loaded — not which
  panel is soldered on.

## Backlight: GPIO, not PWM

`gpio-backlight` holds PD28 high, which is full brightness. The backlight is
really PWM-driven — muOS runs it at 50 kHz — but the H616 PWM controller has no
mainline driver and carrying the out-of-tree one costs about 1900 lines of
patch for brightness control alone. ROCKNIX's own series drives it as a plain
GPIO before switching to PWM, so this buys first light for nothing.

PD28 is the right pin from two directions: muOS's vendor DT for this device
sets `lcd_pwm_ch = 0` and muxes `pwm0` onto PD28, and PD28 is the only pin in
6.18.44's H616 pinctrl carrying a `pwm0` function.

## Which ROCKNIX patches this was drawn from

Provenance, kept because it is the trail back to where the display work started
and the patch numbers are otherwise only findable by reading ROCKNIX's tree:

| Patch | What it was for |
|---|---|
| `0003-Update-sun8i_tcon_top.c.patch` | TCON top |
| `0008-…introduce_allwinner_h616_pwm_controller.patch` | H616 PWM controller — upstream submission in flight |
| `0010-rg35xx-enable-pwm-backlight.patch` | PWM backlight, not taken; see the backlight section |
| `0110-…drm_panel_add_generic_mipi_panel_driver.patch` | The generic panel driver — upstream posting v2, 2025-02-26 |
| `0111-rg35xx-2024-use-panel-mipi-dpi-spi-driver.patch` | Adds the `panel-mipi-dpi-spi` fallback compatible |
| `0151-phy-fix-OTG-host-mode.patch` | The OTG phy, which turned out to matter for USB rather than display |
| `0155-sun4i-set-rgb-connector-as-DSI.patch` | sun4i RGB connector treated as DSI |

Deliberately not taken: `0140-rg35xx-2024-use-rocknix-joypad-driver.patch` and
its friends pull in an out-of-tree joypad driver, and `0127-enable-mmc1-*` is
ROCKNIX's approach to the WiFi problem this tree solved differently.

## muOS is the reference, not ROCKNIX

muOS demonstrably drives this panel. Its vendor DT for `rg40xx-v` independently
confirms the wiring — `lcd_gpio_0..4` are PI9, PI10, PI8, PI14, PI15, exactly
the SPI clock, MOSI, chip select, reset and panel supply used here.

Where the two disagree is timings, and muOS's are the proven ones:

| | muOS (vendor) | ROCKNIX (`.panel`) |
|---|---|---|
| Pixel clock | 24 MHz | 27 MHz |
| Total | 768 × 521 | 750 × 600 |
| Refresh | 59.98 Hz | 60.00 Hz |

Since timings live in the blob rather than the device tree, preferring muOS's
means authoring a `.panel` file. That is the documented fallback if ROCKNIX's
blob gives a picture that is present but wrong. The init sequence cannot be got
from muOS at all — it lives in Anbernic's prebuilt vendor kernel, not in any
MustardOS repository.

## The screen is a console

`CONFIG_DRM_FBDEV_EMULATION` and `CONFIG_FRAMEBUFFER_CONSOLE` are on, and both
`extlinux` configs pass `console=tty0` with no `quiet`. This matters beyond
graphics: this board has no usable console — UART0 is on internal test pads —
so before the panel worked, the only way to see why a boot failed was reading
raw card sectors. It obsoletes most of [debugging without a
console](debugging.md).

The cost is that kernel messages scroll over anything an application draws.
That is the right trade during bring-up, because a silent screen cannot be told
apart from a screen that never came up; an application that wants the panel to
itself can unbind fbcon by writing `0` to
`/sys/class/vtconsole/vtcon*/bind` for the console whose `name` contains
"frame buffer". The messages still reach `ttyS0` and `dmesg`.

HDMI is still not described. The SoC nodes exist upstream and ROCKNIX
describes the connector, but nothing here needs it and every node left out is
one that cannot fail.

## Reading a screen that is wrong

Each row distinguishes failures that look identical on the device.

| Observation | Meaning |
|---|---|
| No `/sys/class/drm/card0` | Almost always the panel, not the display engine. sun4i's component master cannot complete without it, so `/sys/class/backlight` appearing while `card0` does not is exactly this. Check `dmesg` for a `request_firmware` failure on `panels/anbernic,rg40xx-v2-panel.panel` — if it says `-2`, the blob was not linked in, so check `CONFIG_EXTRA_FIRMWARE` and that `patches/buildroot/0002` applied |
| `card0` exists, no connector | The panel node is not binding — check `dmesg` for `panel-mipi` |
| Correct mode, screen black | Backlight, or the init sequence never ran. Check `/sys/class/backlight/backlight` exists and that the blob loaded |
| Correct mode, uniform colour that ignores the framebuffer | The DE→TCON path is not carrying frame data, and the panel is not at fault. Read `TCON_TOP_PORT_SEL` at `0x651001c`: its low two bits are the TCON the mixer feeds, and they must be `0`. Then read the frame-end latch, bit 0 of `0x1008104` — if it never sets, the engine is not completing frames. This exact failure is what the missing endpoint `reg` caused; see the top of this file |
| Correct mode, scrambled or rolling | **Wrong panel variant.** One string in the DTS; see above. Not wrong timings |

## Commands worth knowing

All of these took a while to work out. SSH into a Nerves device runs **Elixir,
not a shell**, so `System.cmd` needs absolute paths and `uname` is not even on
`PATH`:

```elixir
# The pixel clock -- proof the TCON is scanning out at all. debugfs is not
# mounted by default.
System.cmd("/bin/mount", ["-t", "debugfs", "none", "/sys/kernel/debug"])
File.read!("/sys/kernel/debug/clk/clk_summary")      # look for tcon-data-clock

# What DRM believes it is doing: plane, framebuffer, format, CRTC, mode.
File.read!("/sys/kernel/debug/dri/0/state")

# Does anything reach the panel? Solid red, XRGB8888.
File.write("/dev/fb0", :binary.copy(<<0, 0, 255, 0>>, 640 * 480))

# Read a display-engine register directly. muOS has devmem at the same path,
# so the same command compares a working configuration against this one.
System.cmd("/sbin/devmem", ["0x11C1010", "32"])   # UI layer 0 framebuffer address
```

`devmem` is here because `busybox/busybox.fragment` re-enables it —
nerves-common's busybox config turns it off, and its absence is what stopped a
debugging session. Registers owned by a driver can also be read through
`/sys/kernel/debug/regmap/1100000.mixer-{layers,top,display}`, but the DE clock
window at `0x1008000` has no regmap, so `devmem` is the only way to see it.
[The DE33 register map](de33-register-map.md) lists the addresses worth
reading, with the values to expect.

`modetest` needs stdin held open or it drops the mode as it exits:

```
sleep 300 | modetest -M sun4i-drm -s 53:640x480
```

`libdrm`'s test tools ship for exactly this: `modetest` enumerates connectors,
CRTCs and modes and can draw a test pattern without the application running.

## The GPU

`panfrost` builds, the Mali node is enabled, and Mesa ships with GLES2, EGL and
GBM. `kmscube` is in the image as the smallest honest test of the whole stack:
it opens the DRM device, creates a GBM surface, brings up EGL, and spins a
GLES2 cube. It runs correctly on this board — Mali-G31 via Panfrost, GLES 3.1,
shaders linked.

`panfrost … error -110` in an early `dmesg` was a deferred-probe timeout in the
headless build, before the display existed.
