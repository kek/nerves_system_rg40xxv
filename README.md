# Nerves System: Anbernic RG40XXV

This is the base Nerves System configuration for the [Anbernic
RG40XXV](https://anbernic.com/products/rg-40xxv) handheld — a 4", vertical,
Allwinner H700 device.

> [!NOTE]
> Not published to Hex yet, so there is no version badge and no `"~> 0.1"`
> dependency to add. Use a path or git dependency as shown below.

**Confirmed working on a physical RG40XXV**: it boots, joins WiFi on 5 GHz,
answers SSH over both WiFi and the USB-C cable, drives the 4" panel, runs
GLES2 on the Mali GPU, and switches itself off when told to.

| Feature              | Description                                          |
| -------------------- | ---------------------------------------------------- |
| CPU                  | Allwinner H700, quad Cortex-A53 @ 1.5 GHz            |
| Memory               | 1 GB LPDDR3 @ 672 MHz — **not** LPDDR4               |
| Storage              | Two MicroSD slots; ext4/vfat/exFAT/f2fs              |
| Linux kernel         | 6.18.x mainline                                      |
| IEx terminal         | SSH over WiFi or USB gadget; `ttyS0` on internal pads |
| GPIO, I2C, SPI       | Yes, via [circuits](https://github.com/elixir-circuits) |
| WiFi                 | RTL8821CS, mainline `rtw88_8821cs`                   |
| Bluetooth            | RTL8821CS, `btrtl` + H5/3-wire                       |
| Gamepad              | All buttons + volume keys as evdev                   |
| Analog stick         | One, on the GPADC behind a 4:1 mux, with its click   |
| Power                | Power key via `axp20x-pek`; AXP717 soft power-off    |
| Battery / charger    | AXP717, via `/sys/class/power_supply`                |
| Audio                | Speakers + headphone jack with detect                |
| Display              | 4" 640×480 panel, DRM/KMS + framebuffer console      |
| GPU                  | Mali-G31 MC1 via Panfrost, Mesa with GLES2/EGL/GBM   |

## Getting started

Install the Nerves tooling per the [Nerves installation
guide](https://hexdocs.pm/nerves/installation.html), then:

```bash
mix nerves.new my_app
cd my_app
```

In the generated `mix.exs`, set `@all_targets [:rg40xxv]` and replace the
system dependency with this one:

```elixir
{:nerves_system_rg40xxv,
 path: "../nerves_system_rg40xxv", runtime: false, targets: :rg40xxv}
```

or, to pull it straight from git:

```elixir
{:nerves_system_rg40xxv,
 github: "kek/nerves_system_rg40xxv", runtime: false, targets: :rg40xxv}
```

Then:

```bash
export MIX_TARGET=rg40xxv
mix deps.get
mix firmware
mix burn
```

If `~/.nerves/artifacts` already holds a built `nerves_system_rg40xxv`, or a
tagged release publishes one, `mix firmware` takes seconds. A machine that has
to build the system from source is in for a long build and needs roughly
25 GB free.

> [!IMPORTANT]
> `mix nerves.new` also generates an `eth0` entry, which this device does not
> have at all. Remove it or expect a permanently disconnected interface.

## Flashing

> [!WARNING]
> The RG40XXV boots entirely from MicroSD — there is no internal eMMC to
> fall back on. Writing this firmware to the card **destroys the stock
> Anbernic OS on it**. Use a spare card, or image your original card first
> (`dd if=/dev/rdiskN of=stock-backup.img bs=4m`). Keeping the stock card
> intact also gives you a known-good way to confirm the hardware still
> works.

Write to the **OS slot** — the slot the device boots from, `mmc0` in the
device tree. Then insert and power on. `mix burn` handles this. To write a card
by hand:

```bash
fwup _build/rg40xxv_dev/nerves/images/my_app.fw -d /dev/rdiskN
```

After the first flash, `mix upload nerves.local` pushes updates over the
network. Firmware goes to whichever of the two slots is not in use, so a bad
update reverts on the next boot.

> [!NOTE]
> **Firmware updates do not rewrite the bootloader.** SPL and U-Boot are
> written only by the `complete` task, because they are not A/B redundant and
> an interrupted in-place rewrite would brick the device. If a *system* update
> changes U-Boot or the environment layout, re-flash the card rather than
> running `mix upload`.

## Getting in

The RG40XXV has no pin header, so plan how you will talk to it **before** you
flash — there is no console to fall back on if you forget.

### WiFi

Put the network in your app's `config/target.exs`:

```elixir
config :vintage_net,
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [%{key_mgmt: :wpa_psk, ssid: "your-ssid", psk: "your-password"}]
       },
       ipv4: %{method: :dhcp}
     }}
  ]
```

`wpa_supplicant`, `wireless-regdb` and the `rtw88` firmware are all in the
image. `nerves_pack` pulls in `nerves_ssh` and `mdns_lite`, so the device
should come up reachable as `nerves.local`.

Two things cost real time to discover:

- **Set a real `regulatory_domain`.** The generated config ships `"00"`, the
  world domain, which marks most 5 GHz channels no-initiate-radiation. A
  5 GHz-only network is then scanned but never joined, which looks exactly
  like a wrong password.
- **Bake in an SSH host key.** `nerves_ssh` cannot generate one on OTP 29
  (see "Known limitations"), so without this the daemon never starts and the
  device is unreachable even with working WiFi.

### USB gadget over the type-C cable

For bringing up a new unit this is the better of the two routes: it needs no
WiFi credentials and no SSH host key baked in, and it cannot be broken by
getting the regulatory domain wrong.

Mainline sets the H700's `usbotg` node to `dr_mode = "peripheral"`, and the
kernel here is built with `USB_CONFIGFS`, `..._ECM`, `..._RNDIS` and `..._ACM`.
Nothing composes a gadget at boot — that is the application's job, as on other
Nerves gadget targets. With `{"usb0", %{type: VintageNetDirect}}` in your
config and a gadget composed via configfs, the device appears on the host as
`Nerves handheldgame` (`1d6b:0104`), serves DHCP, and answers SSH:

```console
$ ifconfig | grep 172.31
	inet 172.31.70.42 netmask 0xfffffffc broadcast 172.31.70.43
$ ssh nerves@172.31.70.41
```

Composing the gadget is a matter of writing to
`/sys/kernel/config/usb_gadget/`; note that configfs is not mounted by the
Nerves skeleton's fstab, so mount it first. CDC-ECM is the function to pick for
macOS and Linux hosts.

### UART0

`ttyS0` is UART0 on the PH pins, which is where the kernel's `stdout-path`
points and where `erlinit` puts IEx by default. On these handhelds it is on
internal test pads, so it means opening the case and soldering. Settings are
115200 8N1.

It is the fullest view of a board that will not boot, but it was **not needed**
during bring-up — every bug was diagnosed over FEL and the SD card instead. Try
[debugging without a console](docs/debugging.md) before reaching for a
soldering iron.

## Known limitations

- **No HDMI.** The SoC nodes are upstream but nothing here describes the
  connector.
- **Nine kernel patches are carried** in `patches/linux/`, none of them
  upstream as of 6.18, so all need checking on a kernel bump. Four are fixes
  found here (`pwrseq_simple` GPIO reset, without which there is no WiFi; a
  sun4i USB phy fix, without which the gadget never enumerates; an AXP717
  soft power-off, without which shutdown falls through to PSCI and the board
  reboots instead; and an mmc prescan skip, without which an empty card slot
  costs a second and a half of boot); five are the H616 display stack. See
  [the display notes](docs/display.md).
- **Two Buildroot patches** in `patches/buildroot/`, applied automatically by
  `mix compile` and described in
  [`patches/buildroot/README.md`](patches/buildroot/README.md).
- **`nerves_ssh` cannot generate host keys on OTP 29** (ssh 6.0.3): the daemon
  dies with `{:error, "No host key available"}` and then crashes in
  `:ssh_system_sup.stop_system(nil)`. Ship host keys in your application's
  `rootfs_overlay` and point `:nerves_ssh`'s `system_dir` at them.
- **The analog stick's mux positions and axis polarity are inferred** from
  mainline's `rg35xx-h.dts`, not measured on this board. The wiring is read
  from muOS's vendor tree and the click is confirmed by pressing, but which
  two of the four mux positions carry X and Y, and which way each axis runs,
  are the one remaining unexercised assumption. The device tree says how to
  settle it; see [verifying it on a
  device](docs/debugging.md#verifying-it-on-a-device).

## Changing the system itself

You only need this if you are editing the BSP rather than using it.

```bash
git clone https://github.com/kek/nerves_system_rg40xxv
cd nerves_system_rg40xxv
mix deps.get
mix compile          # builds via Docker on macOS, natively on Linux
```

That is the whole procedure. `mix compile` also applies the two
[Buildroot patches](patches/buildroot/README.md) the system needs; there is
nothing to apply by hand.

A native Linux build uses Buildroot's [host
tools](https://buildroot.org/downloads/manual/manual.html#requirement-mandatory).
The two a fresh machine most often lacks are `wget` and `bc` (on Arch:
`pacman -S wget bc`). A missing tool stops the build within seconds of
starting and names itself, so a gap costs a minute, not an hour.

> [!WARNING]
> **`mix compile` after a DTS edit ships the *previous* DTB**, with a fresh
> checksum and a fresh firmware UUID to make it look convincing. This has
> already put a wrong device tree on hardware once. [How to break
> it](docs/hacking.md#path-referenced-content-does-not-trigger-rebuilds).

`mix precommit` runs the two cheap checks — formatting and
`tools/check-consistency.sh`. It deliberately does not compile, because
compiling starts an hour-long Buildroot run. See [hacking on the
system](docs/hacking.md) for the rest.

## Digging deeper

The forensics live outside this file. Each of these is written up because the
failure it describes produced no error message anywhere.

| | |
|---|---|
| [The display](docs/display.md) | How the panel works, why it took so long, and how to read a screen that is wrong |
| [What bring-up found](docs/bring-up.md) | The five hardware surprises, and what build-time verification failed to predict |
| [The boot logo](docs/boot-logo.md) | Why the strip is drawn once, and the researched terms of all four marks |
| [Debugging without a console](docs/debugging.md) | FEL, card breadcrumbs, and the on-device verification checklist |
| [Hacking on the system](docs/hacking.md) | Kernel config regeneration, the DTB rebuild trap, the boot chain |
| [DRAM verification](docs/dram-verification.md) | Why this board is LPDDR3, established four ways, and the one open question about the DRAM rail |
| [Bluetooth](docs/bluetooth-notes.md) | The RTL8821CS config blob linux-firmware does not ship, and why `hci0` stayed behind looking healthy without it |
| [The DE33 register map](docs/de33-register-map.md) | Allwinner's undocumented display top block, decoded from the vendor BSP — reference for the next display bug |

## Licensing and provenance

The board device tree is derived from the ROCKNIX/Batocera
`sun50i-h700-anbernic-rg40xx-v.dts` by Philippe Simons, itself an extension
of mainline work by Ryan Walklin and Chris Morgan. It is
`GPL-2.0-only OR BSD-2-Clause`, matching upstream.

This system is structured after
[`nerves_system_mangopi_mq_pro`](https://github.com/nerves-project/nerves_system_mangopi_mq_pro),
the closest existing sunxi Nerves system.
