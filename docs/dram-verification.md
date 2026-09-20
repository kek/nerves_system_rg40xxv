# DRAM type, verified on hardware

**Result: this unit's DRAM is LPDDR3.** Established 2026-08-21 on the device
itself — not by spec sheets, not by this repo's own earlier prose — along four
independent lines:

1. The vendor boot0 that boots this hardware declares `dram_type = 7`, and
   programs LPDDR3 mode registers into the die.
2. The DRAM controller in the running device reports LPDDR3 in its own `MSTR`
   register.
3. A differential FEL test: ROCKNIX's LPDDR3 SPL trains and reads back a 1 MiB
   pattern intact, twice, bracketing a hang from its LPDDR4 SPL.
4. A four-variant FEL matrix built from one U-Boot tree, in which every wrong
   configuration — including two that change nothing but the protocol — fails
   to bring DRAM up.

Line 3 was arrived at independently of lines 1, 2 and 4 — different SPL
binaries, a different readback method, and no shared working notes — and the
two strands were only compared once both were finished. That they agree is
therefore part of the evidence rather than a restatement of it.

## Why it needed verifying at all

The "1 GB LPDDR4" claim circulates in reviews and in the ROCKNIX wiki
(whose RG40XX V hardware table reads "RAM: 1 GB LPDDR4" — verified
directly). Anbernic's own product pages, checked directly for both the
RG40XX V and RG40XX H, say only "RAM: 1GB" with no type at all — the
LPDDR4 attribution is secondhand everywhere it appears. Meanwhile this
repo's
`uboot/uboot.defconfig` selects `CONFIG_SUNXI_DRAM_H616_LPDDR3`, justified
only by documentation written during bring-up ([bring-up.md](bring-up.md)
§1). Nothing committed here was primary evidence: no boot0 dump, no boot
log, no chip photo. A claim and its citation shared an author.

Two external facts reframe the question:

- **ROCKNIX ships two U-Boot builds for H700** — `u-boot-DDR3` and
  `u-boot-DDR4` — and picks between them *per unit* at runtime by reading
  the `vdd-dram` regulator (1.2 V → LPDDR3 build, 1.1 V → LPDDR4 build) in
  `projects/ROCKNIX/devices/H700/bootloader/update.sh`. They have per-model
  device-tree IDs in hand in that same script and still chose a measured
  electrical property to select the bootloader — so model identity is not
  a reliable predictor of DRAM type across the H700 line. Whether two
  RG40XXV units specifically have shipped with different types is
  unobserved by us; what is certain is that both types exist across the
  H700 family, and that this unit is LPDDR3 despite the LPDDR4 label the
  model carries in community documentation. "The H700 family is uniformly
  LPDDR4" is simply wrong.
- **Allwinner's H700 product brief** lists the memory interface as
  "DDR4/DDR3/DDR3L/LPDDR3/LPDDR4" — both types are first-class options for
  H700 designs, so nothing about the SoC settles it.

Their LPDDR3 defconfig
(`anbernic_rg35xx_h700_lpddr3_defconfig`) matches ours nearly byte-for-byte
(same `TPR10=0x402f4489`, ODT, drive strengths, 672 MHz; TPR11 differs in
two bytes), independently corroborating that our parameter set is the
community-validated LPDDR3 set rather than a bring-up invention.

## Which bootloader owns DRAM init here

Everything below assumes our own SPL performs DRAM training. That has to be
established rather than assumed, because the most plausible way for all of this
to be moot is that the type symbol is **inert** — that DRAM init happens inside
a vendor blob and `CONFIG_SUNXI_DRAM_H616_LPDDR3` is never consulted, in which
case LPDDR3 and LPDDR4 would both appear to work.

It is not inert, and the check is cheap. `fwup.conf` writes
`u-boot-sunxi-with-spl.bin` at `UBOOT_OFFSET`, block 16 — byte 8192, which is
exactly where an Allwinner vendor boot0 lives. Ours does not sit beside the
vendor's; it replaces it. Reading the card back through the running system:

```elixir
{:ok, f} = :file.open("/dev/mmcblk0", [:read, :raw, :binary])
{:ok, data} = :file.pread(f, 8192, 65536)
:crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
```

That hashes identical to this repository's own built
`images/u-boot-sunxi-with-spl.bin` for the firmware version the device reports,
and the eGON header at that offset declares **40960** bytes — a mainline sunxi
SPL, where the vendor boot0 declares 65536. There is no vendor blob in this
boot chain.

Two consequences. DRAM init is mainline's `dram_sun50i_h616.c`, compiled from
the symbol in question — which is why setting it to LPDDR4 during bring-up
stopped the SoC responding at all, something an unread value cannot do. And
`mix upload` can never change it: `fwup.conf` writes the SPL only in the
`complete` task, so a different SPL needs `mix burn`, a card out and back. That
is the practical reason the experiments here go through FEL.

## Evidence 1: the vendor boot0, checksum-verified

`tools/dram-type.sh boot0 <file>` decodes a vendor boot0 offline. Four things
the original hand-decode during bring-up did not do:

- **Verifies the eGON checksum** — a 32-bit sum over the header's declared
  length with the checksum field replaced by Allwinner's stamp value. It passes
  on the muOS blob, which proves the image is intact *and* that the header
  layout is the documented one: the arithmetic cannot come out right unless the
  checksum really is at `0x0c` and the length at `0x10`.
- **Cross-checks five consecutive `dram_para` fields** against
  `uboot/uboot.defconfig` — clock, ODT and both drive-strength words all agree.
  That is the struct offset confirmed rather than assumed, which matters because
  a wrong offset still yields twelve plausible-looking words.
- **Reads the mode registers**, which the first decode never looked at and which
  are the strongest signal in the blob. boot0 carries
  `MR1/MR2/MR3 = 0x83/0x1c/0x01`, byte-identical to the sequence u-boot's
  `mctl_phy_init()` writes on its `SUNXI_DRAM_TYPE_LPDDR3` arm — where the
  comment reads *"MR1: nWR=14, BL8"*. LPDDR4 is BL16 and its arm writes
  `0x0, 0x134, …`, nothing alike. These are values the vendor programs into the
  die itself.
- **Refuses to decode** a blob with wrong magic or a failing checksum instead of
  reporting a plausible type from garbage. A decoder that answers confidently
  from a damaged image is worse than one that answers nothing, because the
  answer gets written into a defconfig. `tools/dram-type.sh selftest` checks the
  refusals against synthesised images, in CI.

`dram_type = 7` is `SUNXI_DRAM_TYPE_LPDDR3` per the enum in
`arch/arm/include/asm/arch-sunxi/dram_sun50i_h616.h`, where `DDR3 = 3` and
`DDR4 = 4` — so the non-LP variants are excluded by the same number.

## Evidence 2: the controller's own MSTR register

No file can say what the silicon is *driving*. `MSTR`, at
`SUNXI_DRAM_CTL0_BASE` = `0x047FB000` on the H616, holds the device type in
bits `[5:0]` and the burst length in `[19:16]`; u-boot writes both from the same
switch arm, so they corroborate each other and a disagreement means the read is
wrong rather than the name.

Measured: **`MSTR = 0xc1040008`** — device type `0x08`
(`MSTR_DEVICETYPE_LPDDR3`), burst length 8, full bus width, one rank.

The number was derived from u-boot's expression before the hardware was read:
`BIT(31) | BIT(30) | MSTR_ACTIVE_RANKS(1) | MSTR_BURST_LENGTH(8) |
MSTR_DEVICETYPE_LPDDR3` = `0xc0000000 | 0x01000000 | 0x00040000 | 0x8`. That
prediction sits in the tool's self-test; the silicon returned it bit for bit.
LPDDR4 would have read `0xc1080020`.

Read it with `tools/dram-type.sh device`, which goes through busybox `devmem`.
A stray MMIO read has hung this SoC before (the `0x1200000` incident in the
display work), so this is a read of a live, documented window and not a licence
to poke around; it did not hang when measured.

## Evidence 3: the differential FEL test, with ROCKNIX's own SPLs

### Method

An A-B-A differential test over FEL (Allwinner's USB recovery protocol):
load an SPL built for each DRAM type directly into SRAM, let it attempt
DRAM training, and check whether a 1 MiB random pattern written to
`0x40000000` reads back intact. Nothing persistent is touched. The wrong
type hangs H616-class training — that hang is the whole reason ROCKNIX
needs two builds — so the *pair* of outcomes is a clean oracle on the chip.

Binaries used (staged outside this repository, since they are third-party
build output rather than source):

- `spl-ours.bin` — this system's 0.2.0 `u-boot-sunxi-with-spl.bin`.
- `spl-rocknix-DDR4.bin`, `spl-rocknix-DDR3.bin` — cut from the 8 KiB
  offset of ROCKNIX release `20260801`'s DDR4/DDR3 images.

Each binary was fingerprinted by its compiled-in TPR10 immediate before
use: ours and ROCKNIX-DDR3 contain `0x402f4489` (LPDDR3 set),
ROCKNIX-DDR4 contains `0x402f6633` (upstream's LPDDR4 set). So each SPL
verifiably *is* what its name claims, independent of anyone's docs.

FEL entry on this device: remove both SD cards, USB-C into the OTG port,
power on — the BROM finds no eGON image and drops into FEL. The probe
reports `soc=00001823(H616)`: the H700 is H616 silicon to the BROM.

### Transcript (2026-08-21, sunxi-fel on macOS)

```
$ ./fel-dram-test.sh probe
AWUSBFEX soc=00001823(H616) 00000001 ver=0001 44 08 scratchpad=00027e00 ...

$ ./fel-dram-test.sh lpddr3
== Loading spl-ours.bin via FEL (a hang here means DRAM training failed) ==
== SPL returned. Testing DRAM readback at 0x40000000 ==
RESULT: DRAM trained and 1 MiB pattern read back intact with spl-ours.bin.

$ ./fel-dram-test.sh lpddr4
== Loading spl-rocknix-DDR4.bin via FEL (a hang here means DRAM training failed) ==
usb_bulk_send() ERROR -1: Input/Output Error
RESULT: SPL did not return to FEL — DRAM init hung with spl-rocknix-DDR4.bin.

$ ./fel-dram-test.sh lpddr3
== Loading spl-ours.bin via FEL (a hang here means DRAM training failed) ==
== SPL returned. Testing DRAM readback at 0x40000000 ==
RESULT: DRAM trained and 1 MiB pattern read back intact with spl-ours.bin.
```

LPDDR3 trains and verifies, twice, bracketing an LPDDR4 hang on the same
hardware and cable. The chip is LPDDR3.

## Evidence 4: the four-variant matrix, built from one tree

The differential test above uses two SPLs from different sources. This one
removes that variable: four SPLs from a single U-Boot tree, one toolchain, one
build command, differing only in DRAM configuration.

| variant | configuration | result |
|---|---|---|
| `lpddr3` | ours | **DRAM up**, `0x40000000` and `0x40100000` independent |
| `lpddr4-upstream` | upstream's whole LPDDR4 block, verbatim | SPL hung in DRAM init |
| `lpddr4-typeonly` | type swapped, every analog value unchanged | SPL hung in DRAM init |
| `ddr3-typeonly` | same, DDR3-1333 | SPL hung in DRAM init |

All three possible outcomes were written down before the device was touched: if
the symbol is inert, all four bring up DRAM; if the die is LPDDR4,
`lpddr4-upstream` works and ours never should have; if the die is LPDDR3, only
ours works. The third happened.

The two type-only rows are the sharp instrument. Same 672 MHz clock, same ODT,
same drive strengths, same TPR words — only the protocol differs, and a working
DRAM init becomes a hang. Nothing that is never consulted can do that, which
retires the inert-symbol hypothesis experimentally as well as structurally.

`lpddr4-upstream` answers the LPDDR4 label directly: it is the configuration
upstream ships for the H700 Anbernic usually called identical hardware, at the
same clock upstream pairs with it, and it does not train this memory.

A variant counts as working only if **two addresses 1 MB apart round-trip
independently**. `readl` answering is not enough — right timings with wrong
geometry give a DRAM that answers, aliases, and corrupts Linux an hour later.

Run it with `tools/dram-falsify.sh matrix`. The outcomes above are recorded
inside the tool, so a later run compares against them and reports a
disagreement as the finding: if the DRAM values are ever changed, this matrix
should still come out this way.

## The tools

Three, with different costs and different reaches.

| | what it needs | what it answers |
|---|---|---|
| `tools/dram-type.sh boot0` | a vendor boot0 dump | what the manufacturer programs |
| `tools/dram-type.sh device` | a running device, ssh | what the controller is driving |
| `tools/dram-falsify.sh` | Docker, FEL, hands on the device | whether the wrong configurations fail |

The first two are cheap and repeatable and belong in any doubt about this
question. The third needs the device in FEL mode — both SD cards out, USB-C to
the OTG port, power on — and costs a power cycle per wrong answer. Evidence 3
used a separate set of ROCKNIX-built SPLs that is not kept here; `dram-falsify`
builds its own from one tree, which is the reproducible version of the same
experiment.

`tools/check-consistency.sh` also asserts the DRAM block on every push: LPDDR3
selected, LPDDR4 not, the five boot0-derived values intact, and `TPR6`/`TPR10`
present (they have no Kconfig default, and omitting one makes the build wait for
input rather than fail). That is the guard against a future reconciliation with
upstream quietly restoring the setting that produces a device indistinguishable
from dead hardware.

Building the `dram-falsify` variants happens in a small Debian container rather
than on the host. U-Boot's host tools want OpenSSL headers, `swig` and
`pylibfdt`, and on macOS `pylibfdt` fails to *link* — a Python extension needs
`-undefined dynamic_lookup`, which U-Boot's `setup.py` does not pass. Buildroot
builds U-Boot in Linux for the same reasons. Also note macOS `make` is GNU Make
3.81, which predates `undefine` and dies in U-Boot's Makefile; `gmake` works.

## Resolved: vdd-dram was 100 mV under the vendor's own value

Our SPL set `CONFIG_AXP_DCDC3_VOLT=1100` and the inherited upstream DTS pinned
the `vdd-dram` regulator always-on at 1.1 V — the LPDDR4 voltage — on LPDDR3
memory. ROCKNIX's LPDDR3 build uses **1200**, matching LPDDR3's nominal 1.2 V
VDD2.

**Settled by reading Anbernic's own firmware, 2026-08-21.** Booted the muOS card
on this unit and read the PMIC:

    axp2202-dcdc2   940000 uV  enabled
    axp2202-dcdc3  1200000 uV  enabled

So the vendor runs the DRAM rail at **1.2 V**, and our 1.1 V was an import, not
a board characteristic. Worth noting how that reading was made trustworthy: the
vendor's 4.9 kernel calls the PMIC `axp2202` rather than `axp717` and names its
regulators generically, with no `vdd-dram` label, so "dcdc3" had to be confirmed
as the same rail before being believed. `dcdc2` reading exactly 940000 — the
value this repo's own `CONFIG_AXP_DCDC2_VOLT` sets — is that confirmation: the
numbering matches between the two drivers.

This also retires the inference that had been standing in for a measurement.
ROCKNIX picks its U-Boot by reading this rail, 1.2 V meaning LPDDR3, and that
heuristic classifying these units correctly *required* stock to be at 1.2 V.
It is, but the argument is no longer needed.

One consequence of our own pinning is worth keeping: on an image of ours, sysfs
reads whatever we pinned regardless of the chip fitted, so ROCKNIX-style
detection cannot work against our firmware. Only stock or vendor firmware gives
that reading meaning.

### What shipped, and what is still open

Three edits landed together, because all three are in `checksum_files()` and
separately would have cost three full rebuilds (1–3.5 h each, ~25 GB free, and
strictly one build at a time):

1. `uboot/uboot.defconfig`: `CONFIG_AXP_DCDC3_VOLT` 1100 → 1200. The SPL
   programs the AXP717 before DRAM training, so this is the voltage the
   training actually happens at.
2. `linux/sun50i-h700-anbernic-rg40xx-v.dts`: `reg_dcdc3` overridden to
   1200000 by full path. Without it the kernel drags the rail back to 1.1 V at
   regulator registration, and training at 1.2 V and then undervolting mid-run
   is worse than either steady state — so this edit and the one above could not
   land separately:

   ```dts
   &reg_dcdc3 {
           regulator-min-microvolt = <1200000>;
           regulator-max-microvolt = <1200000>;
   };
   ```
3. `nerves_defconfig`: `BR2_PACKAGE_MEMTESTER=y`, the soak tool, riding the
   same rebuild for free.

The cheap FEL check came first, before spending the rebuild, since 1.2 V
failing to train would have made the other two edits moot:
`tools/dram-falsify.sh test lpddr3-vdd1v2` brought DRAM up with two addresses
1 MB apart independent. That arm is the control with `CONFIG_AXP_DCDC3_VOLT`
raised and nothing else touched — the built SPLs differ by seven bytes, one
constant and the eGON checksum — and it is valid on its own because in FEL
there is no kernel to drag the rail back afterwards.

Three checks now hold the pieces together, all running on every push:
`tools/check-consistency.sh` asserts the SPL and the DTS name the same voltage
and fails loudly if they diverge, `tools/check-dts.sh` asserts the value
reached the compiled DTB, and the DTS is consumed through
`BR2_LINUX_KERNEL_CUSTOM_DTS_PATH`, so the path-referenced-content trap
([hacking.md](hacking.md)) applies: an already-stamped linux package would
otherwise ship the previous bytes under a fresh checksum.

**Still open: the two things FEL cannot show.** Nothing has been burned since,
so our own rail has never been read on a running system at 1.2 V, and no soak
has run.

- *Rail confirmation.* Burn and boot, then read
  `/sys/class/regulator/*/microvolts` for `vdd-dram`. It should say 1200000,
  and for the first time the reading is meaningful rather than an echo of our
  own pin — which also un-blinds ROCKNIX-style detection on our image.
- *Soak.* `memtester 700M <loops>` from an SSH/IEx session (`System.cmd`). The
  device has 1 GB, so ~700 MB locks most of what Linux and the BEAM leave free.
  Several hours to overnight, run warm — shell closed, CPU and GPU loaded
  alongside — because marginal DRAM fails hot and not on an idle bench.

The soak is not what decides whether to ship 1.2 V; the vendor's own value
decides that. It is confirmation that we match the vendor in practice, and the
more interesting question it can still answer is whether the previous 1.1 V was
doing quiet damage. Detecting that needs a soak at the *old* voltage, which
means either a second full rebuild with only `DCDC3_VOLT` reverted or accepting
this unit's boot-and-run history at 1.1 V as an informal control. (A
runtime-switchable rail — a widened DTS range plus a userspace regulator
consumer — would allow a same-build A/B, at more kernel-config complexity than
the question is worth.) So it stays an open question about the past rather than
a risk in the present.

If the soak is ever run: no errors at 1.2 V warm means at least as good as
1.1 V, matching both the community build and the chip's nominal spec. Errors at
1.1 V but not at 1.2 V would mean the undervolt was a real margin problem.
Errors at both would mean the problem is not voltage, and the timings are next.

The risk either way is low. 1.2 V is LPDDR3's nominal VDD2 and exactly what
ROCKNIX's LPDDR3 build programs into the same PMIC on the same boards. The
worst case is a non-booting SD image, recovered by reflashing the known-good
0.2.0 image or over FEL; nothing here can brick an SD-boot device.

## If this ever needs re-verifying

Start with `tools/dram-type.sh device`, which is one register read and needs
nothing but ssh, then `tools/dram-type.sh boot0` if a vendor card is to hand.
For the destructive-looking end of it, `tools/dram-falsify.sh matrix` rebuilds
and reruns the whole matrix against its recorded outcomes.

Evidence 3 can be reconstructed from sunxi-tools plus any LPDDR3/LPDDR4 SPL
pair whose TPR10 fingerprints have been verified, though the matrix above
supersedes it. Definitive alternatives: photograph the DRAM package
marking and decode the part number, or dump the vendor boot0 from a stock
or muOS card (`dd bs=512 skip=16 count=256`) and read `dram_para` offset
`0x38`: 7 = LPDDR3, 8 = LPDDR4.
