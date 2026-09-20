# Debugging without a console

The device has no pin header and the LED tells you nothing. Before the panel
worked there was no display either, and the techniques below are what covered
the whole boot chain without opening the case. The framebuffer console
obsoletes most of this — but only for failures that get as far as Linux.

**FEL, for anything before Linux.** The H700's BROM exposes Allwinner's USB
recovery protocol, which lives in mask ROM and therefore works even when
nothing on the card boots. Power on with **no SD card** and connect USB-C:

```bash
sunxi-fel -l                     # the H700 reports as H616, SoC ID 0x1823
sunxi-fel spl images/u-boot-sunxi-with-spl.bin   # runs our SPL, which inits DRAM
sunxi-fel readl 0x40000000       # DRAM answers => init succeeded
sunxi-fel writel 0x40000000 0xcafebabe
sunxi-fel readl 0x40000000       # round-trips => DRAM is genuinely usable
```

This is how the LPDDR3 bug was found. A device that vanishes from USB after
`spl` has hung the SoC in DRAM init. Write two addresses 1 MB apart and read
the first back to check for aliasing, which indicates wrong geometry rather
than wrong timings — that failure mode boots the SPL happily and corrupts
Linux later.

**Card breadcrumbs, for userland.** There is ~17 MB of unallocated space
between the U-Boot environment (ends block 8448) and rootfs A (block 43008).
An application can write diagnostics there with a plain `File.write` to
`/dev/mmcblk0` at a block offset, then you power off and read it on a host
with `dd`. Combined with `RingLogger`, that yields the complete boot log —
kernel messages included, because `nerves_logging` feeds kmsg into Logger.
Prefer this over the U-Boot environment: a bad write there stops the device
booting, whereas this region is only touched by a full re-flash.

**The card itself records two boot facts**, readable with `dd` and no
instrumentation at all:

- `nerves_fw_booted` in the U-Boot environment at `0x400000` flips 0 → 1 the
  first time `bootcmd` runs. It is deliberately shipped as 0 for this reason.
- The application data partition is written as `0xff` by fwup and reformatted
  to f2fs on first boot. f2fs magic at block 1615872 + 1024 therefore proves
  the kernel ran and reached erlinit's mount stage.

Together those two bracket the failure: environment untouched means U-Boot
never ran; environment updated but partition still `0xff` means the kernel
never started; both changed means the failure is in userland.

## Verifying it on a device

This procedure has been run on a physical RG40XXV. It is still worth following
on a new unit or after changing the system, because most of it is unexercised
by CI.

### 1. Bake in WiFi and SSH before flashing

See "Getting in" in the README. There is no console to fall back on if you
forget, and `mix firmware && mix burn` destroys the stock Anbernic OS on that
card — image your original first, or use a spare. The stock card is also your
control experiment if the device shows no signs of life.

### 2. Power on

The panel now shows the kernel log, so a boot that reaches Linux says so on
its own screen. If it does not, use FEL rather than guessing; do not read
anything into the LED.

### 3. Get in

```bash
ssh nerves.local
```

**If this works, you have already proved a lot.** Reaching the device over
WiFi means `mmc1` was enabled, which means *our* device tree loaded rather
than U-Boot's built-in `rg35xx-2024` — that one carries no WiFi at all. So
a successful SSH rules out the failure this system was most at risk of.

Confirm it explicitly anyway:

```elixir
cmd "cat /proc/device-tree/model"     # => Anbernic RG40XX V
```

### 4. Check the buttons, and then the stick — the least certain thing here

The button GPIO mapping was inherited from mainline's `rg35xx-plus.dts` on the
premise that the RG40XXV is the same board family, and it has since been
exercised: every button drives a launcher on this hardware, and the stick's
click was confirmed by pressing it.

What is still inferred is the analog stick's axes. The mux wiring comes from
muOS's vendor tree, but which two of the four mux positions carry X and Y, and
which way round each axis runs, are taken from the two-stick sibling board.
The stick check at the end of this section is the one most likely to find
something.

List what the kernel found:

```elixir
cmd "cat /proc/bus/input/devices"
```

You should see the gamepad and volume `gpio-keys` devices. To watch actual
presses, add `{:input_event, "~> 1.4"}` to your app and:

```elixir
{:ok, _} = InputEvent.start_link("/dev/input/event0")
# press buttons, then:
flush()
```

That is the better tool because it streams into IEx without blocking. The
image also ships `evtest`, but plain `evtest` never exits and busybox here
has no `timeout`, so it will wedge an IEx session. Use its one-shot query
form instead — hold the button down and run:

```elixir
# exit status 10 means "currently pressed"
cmd "evtest --query /dev/input/event0 EV_KEY BTN_SOUTH"
```

Work through every button and check the reported codes match the physical
layout. If they don't, the fix is small: the pins live in one `gpio-keys`
node inherited from the parent DTS, and can be overridden in
`linux/sun50i-h700-anbernic-rg40xx-v.dts`.

Then settle the stick. All four mux positions are declared, so all four appear
in sysfs — move the stick while reading them:

```elixir
cmd "cat /sys/bus/iio/devices/iio:device0/in_voltage0_raw"   # and 1, 2, 3
```

The two that move are the stick; which way each one travels gives the
polarity, and the extremes give the real range in place of the nominal
`0..4096` the device tree assumes. The `adc-joystick` comment in
`linux/sun50i-h700-anbernic-rg40xx-v.dts` has the full account.

### 5. Everything else

```elixir
# which drivers actually bound
cmd "dmesg | grep -iE 'axp717|rtw88|mmc|sunxi|panfrost'"

# battery and charger (list first -- do not assume the name)
cmd "ls /sys/class/power_supply/"
cmd "cat /sys/class/power_supply/*/capacity /sys/class/power_supply/*/voltage_now"

# LEDs, including the RGB one on PI7
cmd "ls /sys/class/leds/"

# audio
cmd "aplay -l"
cmd "speaker-test -c 2 -t sine -l 1"

# the GPU, end to end
cmd "kmscube -n 100"

# firmware metadata round-trips through the U-Boot environment
cmd "fw_printenv nerves_fw_active"
```

For a screen that is present but wrong, see [the display
notes](display.md#reading-a-screen-that-is-wrong).

### 6. If it never gets far enough to SSH

Use FEL and the card breadcrumbs above. Every bug found during bring-up was
diagnosed that way; opening the case for UART was never necessary.

UART0 remains the fullest option if you want it — `ttyS0`, 115200 8N1, 3.3V
logic, on internal test pads. Two changes make it more useful, and both need
a system rebuild, so make them before your first build if you expect to need
them:

- Add `ignore_loglevel earlycon` to the `append` line in
  `rootfs_overlay/boot/extlinux/extlinux-a.conf` for early kernel output. The
  line ships `loglevel=5`, which keeps info-level messages off the consoles to
  save about 1.5 s of synchronous UART writes, so `ignore_loglevel` is what
  brings them back. Bare `earlycon` resolves because the device tree sets
  `chosen/stdout-path = "serial0:115200n8"`.
- Set `CONFIG_BOOTDELAY=1` in `uboot/uboot.defconfig` so you can interrupt
  U-Boot. It is 0 here for fast boot, which is the wrong trade-off while
  bringing a board up.

### What to report back

If something fails, the useful details are: which stage above it reached, the
full `dmesg`, and `cat /proc/device-tree/model`. Those three narrow it down to
bootloader, device tree, or driver almost immediately.
