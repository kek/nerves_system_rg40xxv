# The DE33 top block, decoded from the vendor BSP

**Source review only — nothing here was ever measured on hardware.** It was
written while the display still showed a uniform green screen, to decode
registers mainline documents nowhere.

The display was fixed afterwards, and not by anything on this page: the mixer
was routed to the wrong TCON, which [the display notes](display.md) cover in
full. So every *lead* below is closed. What survives is
the register map, four corrections to earlier claims, and one diagnostic trick —
kept because this silicon has no public documentation and the next display bug
will want them.

## Where it comes from

`orangepi-xunlong/linux-orangepi`, branch `orange-pi-4.9-sun50iw9`, path
`drivers/video/fbdev/sunxi/disp2/disp/de/lowlevel_v33x/de330/` — Allwinner's own
BSP for sun50iw9, the same SoC family as the H700 and the same 4.9 kernel line
muOS runs. Files: `de_top.c`, `de_top.h`, `de_rtmx.c`, `disp_al_de.c`. The 5.15
`sun55iw3` BSP was checked too; its `de_top.c` is materially identical.

The handles to re-derive any of this, since the offsets below are worth less
than the ability to check them: `de_top_set_rtmx_enable()` and
`de_top_enable_irq()` with the `de_irq_flag` enum give `GLB_CTL`;
`de_top_query_state_with_clear()` with `de_irq_state` gives `GLB_STS`;
`de_top_set_clk_enable()` covers the MBUS clock; `de_top_set_uchn2core_mux()`
gives the channel arithmetic; `struct bld_reg`, `struct bld_pipe_attr` and
`struct ovl_u_lay_reg` give the blender and layer layouts, with `pipe0_en` …
`pipe5_en` at bits 8–13 and `win_size` at `0x88`. On the mainline side the
counterparts are `sun50i_h616_mixer0_cfg`, `sun8i_ui_layer_init_one()`,
`SUN8I_MIXER_GLOBAL_CTL_RT_EN` and the `SUN8I_MIXER_CHAN_UI_*` macros.

Not muOS's own source — MustardOS has no kernel repo — but the vendor BSP for
the same silicon, which is why it settles naming questions that reading mainline
cannot.

## The map

`de_base` is `0x1000000` on this board. Everything from `0x8100` is **per
display pipeline**, stride `disp * 0x40`, not global to the DE.

| Offset | Absolute | BSP name | Meaning |
|---|---|---|---|
| `0x8000` | `0x1008000` | `ahb_reset_adr` | AHB reset, one bit per block: CORE0–3 = bits 0–3, WB = bit 4 |
| `0x8004` | `0x1008004` | `mod_en_adr` | Module clock enable, same bit positions |
| `0x8008` | `0x1008008` | `DE_MBUS_CLOCK_ADDR` | DE MBUS clock enable (bit 0) |
| `0x8010` | `0x1008010` | `DE2TCON_MUX_OFFSET` | DE→TCON mux, 2 bits per disp |
| `0x8014` | `0x1008014` | `DE_VER_CTL_OFFSET` | IP version |
| `0x8020` | `0x1008020` | `DE_RTWB_MUX_OFFSET` | Real-time writeback mux |
| `0x8024` | `0x1008024` | `DE_CHN2CORE_MUX_OFFSET` | Channel→core mux (mainline `CHN2CORE`) |
| `0x8028 + disp*4` | `0x1008028` | `DE_PORT2CHN_MUX_OFFSET` | Port→channel mux, 4 bits per port (mainline `PORT02CHN`) |
| `0x80E0` | `0x10080E0` | `DE_DEBUG_CTL_OFFSET` | Debug/LUT control |
| `0x8100` | `0x1008100` | `RTMX_GLB_CTL` | Real-time mixer global control |
| `0x8104` | `0x1008104` | `RTMX_GLB_STS` | Real-time mixer global status |
| `0x8108` | `0x1008108` | `RTMX_OUT_SIZE` | `(h-1)<<16 \| (w-1)` |
| `0x810C` | `0x100810C` | `RTMX_AUTO_CLK` | Auto clock gating |
| `0x8110` | `0x1008110` | `RTMX_RCQ_CTL` | RCQ update trigger; `+4`/`+8` head address lo/hi, `+0xC` length |

**`GLB_CTL` bits** (from `de_top_set_rtmx_enable()` and `de_top_enable_irq()`):
0 = real-time mixer enable, 4 = frame-end IRQ enable, 6 = RCQ-finish IRQ enable,
7 = RCQ-accept IRQ enable.

**`GLB_STS` bits**, all write-1-to-clear: 0 = frame end, 2 = RCQ finished,
3 = RCQ accepted. Bits 4 and 8 are named by neither the 4.9 nor the 5.15 BSP.

## The diagnostic worth keeping

**Bit 0 of `0x1008104` is the frame-end latch.** Measured back then: muOS `0x111`,
this tree `0x100` — the vendor had completed frames and this tree never had.

That makes it a one-read progress oracle. Any change that makes bit 0 start
latching has moved the DE from "never completes a frame" to "completes frames",
which beats forming a judgement about the colour of a screen. `display.md`'s
"frame-end latch running" is this register.

## Four claims this corrected

**Patch `0104`'s "unknown" bit 6 is an RCQ-finish interrupt enable**, for a
register-configuration-queue mechanism this tree does not use. So the patch
**cannot affect scanout**, which is why it changed nothing, and "the vendor sets
this bit" was never evidence of a missing enable — it is evidence the vendor
drives the DE in RCQ mode.

**Two blender registers were mislabelled**, and a conclusion rested on one:

| Address | Called | Actually |
|---|---|---|
| `0x1281000` | `BLEND_PIPE_CTL` | correct |
| `0x1281004` | `BLEND_BKCOLOR` | `BLEND_ATTR_FCOLOR(0)` — pipe 0's *fill* colour |
| `0x1281008` | `BLEND_OUTSIZE` | `BLEND_ATTR_INSIZE(0)` — pipe 0's *input* size |

The real ones are `BLEND_ROUTE` `0x1281080`, `BLEND_BKCOLOR` `0x1281088`
(expect `0xFF000000`), `BLEND_OUTSIZE` `0x128108C` (expect `0x01DF027F`). The
claim that "the vendor's background is black, so the green is not a configured
background" had been read off pipe 0's fill colour, and was withdrawn.

**`0x1101000` reading zero on muOS was never suspicious.** That is the *video*
channel and neither side uses it. Both scan out a **UI** channel. Overlay bases:
VI 0 → `0x1101000`, **UI 0 (physical 6) → `0x11C1000`**, UI 1 → `0x11E1000`,
UI 2 → `0x1201000` (**avoid** — adjacent to the region that hung the SoC).
`de_top_set_uchn2core_mux()` shifts by `((phy_chn - 6) << 1) + 16`, so UI
channels are physical 6, 7, 8 — independently confirming mainline's
`.map = {0, 6, 7, 8}`.

**`GLOBAL_DBUFF` is correctly skipped on DE33.** The real commit trigger is
`RTMX_RCQ_CTL`, meaningful only in RCQ mode; in non-RCQ mode
`de_rtmx_update_reg_ahb()` just `memcpy`s dirty shadow blocks into MMIO. So
mainline's `if (de_type != SUN8I_MIXER_DE33)` guard is architecturally right and
direct register writes are a legitimate way to drive this hardware.

## Where mainline diverges, and gets away with it

Only the **top block** differs between DE2 and DE33, and mainline reuses the DE2
tables there:

| Offset | Mainline (DE2 tables) | Vendor (DE33) |
|---|---|---|
| `0x00` | Module clock gate | AHB reset |
| `0x04` | Bus clock gate | Module enable |
| `0x08` | AHB reset | **MBUS clock** |
| `0x0c` | Divider (M) | unused |

`sun50i_h616_de33_clk_desc` reuses `sun8i_h3_de2_hw_clks` and
`sun50i_h5_de2_resets` unchanged, so bringing up mixer0 sets bit 0 of `0x00`,
`0x04` *and* `0x08` — reset-deassert, module enable and MBUS clock under the
vendor layout. All three land at 1 either way, because mixer0 is bit 0 in both
mappings. It works by coincidence, and that coincidence is worth knowing before
anyone touches the DE clock driver.

Everything else was checked offset by offset against the BSP structs and
matches: `struct bld_reg` (`rout_ctl` `0x80`, `premul_ctl` `0x84`, `bg_color`
`0x88`, `out_size` `0x8c`), channel addressing (`map[ch] * 0x20000 + 0x1000`),
and `struct ovl_u_lay_reg` against the `SUN8I_MIXER_CHAN_UI_*` macros — that struct
is ctl, size, coord, pitch, `top_laddr`, `bot_laddr`, fcolor over a `0x20`
stride, then `top_haddr` `0x80`, `bot_haddr` `0x84`, `win_size` `0x88`.

One real difference: **DE33 has six blender pipes** (bits 8–13) where mainline's
`SUN8I_MIXER_BLEND_PIPE_CTL_EN_MSK` is `GENMASK(12, 8)` — five. Harmless with a
single plane on pipe 0; it matters if more planes are ever used.

**`BLEND_ROUTE` looks like a bug and is not.** Four bits per pipe select which
blender port feeds it, and mainline writes the *logical* channel index. The
vendor's own `PORT02CHN` constant `0xa980` explains why that is right: port 0 →
`0x0` (VI 0), port 1 → `0x8` (UI 0, written as `phy_chn + 2`), port 2 → `0x9`,
port 3 → `0xa`. Port index and logical channel index coincide by construction.

## The UI layer block, for next time

Never read on either side. Expected values are for fbcon's 640×480 `XR24`
buffer at pitch 2560:

| Address | Register | Expected |
|---|---|---|
| `0x11C1000` | layer 0 `ATTR` | bit 0 set, format `XRGB8888` at bits 8–12 |
| `0x11C1004` | layer 0 `SIZE` | `0x01DF027F` |
| `0x11C1008` | layer 0 `COORD` | `0x00000000` |
| `0x11C100C` | layer 0 `PITCH` | `0x00000A00` (2560) |
| `0x11C1010` | layer 0 `TOP_LADDR` | a framebuffer address, `0x4xxxxxxx` |
| `0x11C1080` | `TOP_HADDR` | `0x00000000` |
| `0x11C1088` | `OVL_SIZE` | `0x01DF027F` |

`TOP_LADDR` is the informative one: zero or implausible means the DE is pointed
at nothing and the fault is above the hardware; a sane DRAM address means it has
been told where the pixels are and still does not fetch them. And mainline
rewrites `ATTR` bit 0 on every commit with the comment "it can clear
spontaneously for unknown reasons" — reading it back as 0 on a supposedly
enabled plane would be worth more than any other single result here.

## How to read these

`/sbin/devmem` is on both sides — `busybox/busybox.fragment` turns it back on,
since nerves-common's config disables it. Over SSH this image answers with
Elixir rather than a shell:

```elixir
System.cmd("/sbin/devmem", ["0x11C1010", "32"])
```

Driver-owned registers can also be read through regmap debugfs —
`/sys/kernel/debug/regmap/1100000.mixer-{layers,top,display}` after
`mount -t debugfs none /sys/kernel/debug`. That covers the mixer windows but
**not** the DE clock window at `0x1008000`: no driver exposes a regmap for it,
which is exactly why `devmem` had to come back.

> Reading DE33 addresses speculatively **hangs the SoC**. One address at a time,
> only in windows known to respond, and stay away from `0x1200000`.
