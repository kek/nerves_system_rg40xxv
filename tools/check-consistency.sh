#!/bin/bash
#
# Assert that the five files describing the image layout agree with each
# other.
#
#   fwup_include/fwup-common.conf   partition offsets and sizes
#   uboot/uboot.defconfig           where U-Boot keeps its environment
#   uboot/uboot.env                 which partition each slot boots
#   rootfs_overlay/etc/fw_env.config  where Elixir reads that environment
#   rootfs_overlay/boot/extlinux/*  which partition each slot mounts as root
#   rootfs_overlay/etc/erlinit.config where the app data partition is mounted
#
# None of these disagreements produce a build error. They produce a device
# that boots the wrong rootfs, mounts nothing at /root, or silently loses its
# firmware metadata -- so they are worth asserting mechanically.
#
# Pure shell and awk, no Docker, no network.
#
set -euo pipefail

cd "$(dirname "$0")/.."

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }

val() { # val <file> <define-name>
    awk -v n="$2" '$0 ~ "^define\\("n"," {
        line=$0
        sub(/^define\([^,]*,[[:space:]]*/, "", line)
        sub(/\).*$/, "", line)
        gsub(/"/, "", line)
        print line
        exit
    }' "$1"
}

COMMON=fwup_include/fwup-common.conf

UBOOT_OFFSET=$(val $COMMON UBOOT_OFFSET)
UBOOT_COUNT=$(val $COMMON UBOOT_COUNT)
ENV_OFFSET=$(val $COMMON UBOOT_ENV_OFFSET)
ENV_COUNT=$(val $COMMON UBOOT_ENV_COUNT)
ROOTFS_A_OFFSET=$(val $COMMON ROOTFS_A_PART_OFFSET)
ROOTFS_A_COUNT=$(val $COMMON ROOTFS_A_PART_COUNT)
APP_DEVPATH=$(val $COMMON NERVES_FW_APPLICATION_PART0_DEVPATH)
APP_FSTYPE=$(val $COMMON NERVES_FW_APPLICATION_PART0_FSTYPE)
APP_TARGET=$(val $COMMON NERVES_FW_APPLICATION_PART0_TARGET)

echo "==> image layout"

# U-Boot must not run into its own environment block.
if [ $((UBOOT_OFFSET + UBOOT_COUNT)) -le "$ENV_OFFSET" ]; then
    ok "U-Boot ($UBOOT_OFFSET..$((UBOOT_OFFSET + UBOOT_COUNT))) ends at or before env ($ENV_OFFSET)"
else
    fail "U-Boot overruns its environment block"
fi

# The environment must not run into rootfs A.
if [ $((ENV_OFFSET + ENV_COUNT)) -le "$ROOTFS_A_OFFSET" ]; then
    ok "env ends at or before rootfs A ($ROOTFS_A_OFFSET)"
else
    fail "U-Boot environment overlaps rootfs A"
fi

# Partitions should sit on 1 MiB boundaries (2048 sectors of 512 bytes).
for pair in "ROOTFS_A_PART_OFFSET:$ROOTFS_A_OFFSET" "ROOTFS_A_PART_COUNT:$ROOTFS_A_COUNT"; do
    name=${pair%%:*}; v=${pair#*:}
    if [ $((v % 2048)) -eq 0 ]; then ok "$name ($v) is 1 MiB aligned"
    else fail "$name ($v) is not 1 MiB aligned"; fi
done

echo "==> U-Boot environment location agrees in three places"

# fwup counts 512-byte sectors; U-Boot and fw_env use byte offsets.
want_off=$(printf '0x%x' $((ENV_OFFSET * 512)))
want_size=$(printf '0x%x' $((ENV_COUNT * 512)))

uboot_off=$(awk -F= '/^CONFIG_ENV_OFFSET=/ {print tolower($2)}' uboot/uboot.defconfig)
uboot_size=$(awk -F= '/^CONFIG_ENV_SIZE=/ {print tolower($2)}' uboot/uboot.defconfig)

[ "$uboot_off" = "$want_off" ] \
    && ok "CONFIG_ENV_OFFSET=$uboot_off matches sector $ENV_OFFSET" \
    || fail "CONFIG_ENV_OFFSET=$uboot_off but fwup puts it at $want_off"
[ "$uboot_size" = "$want_size" ] \
    && ok "CONFIG_ENV_SIZE=$uboot_size matches $ENV_COUNT sectors" \
    || fail "CONFIG_ENV_SIZE=$uboot_size but fwup reserves $want_size"

# fw_env.config: "<device> <offset> <size>", ignoring comments.
read -r fwenv_dev fwenv_off fwenv_size < <(
    grep -vE '^[[:space:]]*(#|$)' rootfs_overlay/etc/fw_env.config | head -1
)
[ "$(echo "$fwenv_off" | tr 'A-F' 'a-f')" = "$want_off" ] \
    && ok "fw_env.config offset $fwenv_off matches" \
    || fail "fw_env.config offset $fwenv_off but expected $want_off"
[ "$(echo "$fwenv_size" | tr 'A-F' 'a-f')" = "$want_size" ] \
    && ok "fw_env.config size $fwenv_size matches" \
    || fail "fw_env.config size $fwenv_size but expected $want_size"

echo "==> partition numbering"

# fwup's mbr slots are 0-based, Linux device names are 1-based, and slot 0 is
# intentionally empty. So slot 1 -> p2 (rootfs A), 2 -> p3 (B), 3 -> p4 (app).
for spec in "extlinux-a.conf:2" "extlinux-b.conf:3"; do
    f=rootfs_overlay/boot/extlinux/${spec%%:*}; want=p${spec#*:}
    if grep -q "root=/dev/mmcblk0${want} " "$f"; then
        ok "${spec%%:*} boots /dev/mmcblk0${want}"
    else
        fail "${spec%%:*} does not set root=/dev/mmcblk0${want} (got: $(grep -o 'root=[^ ]*' "$f" | head -1))"
    fi
done

# uboot.env selects the partition sysboot reads extlinux.conf from.
grep -q 'setenv uenv_part 2' uboot/uboot.env \
    && ok "uboot.env maps slot a to partition 2" \
    || fail "uboot.env does not map slot a to partition 2"
grep -q 'setenv uenv_part 3' uboot/uboot.env \
    && ok "uboot.env maps slot b to partition 3" \
    || fail "uboot.env does not map slot b to partition 3"

echo "==> application partition"

# erlinit mounts it; fwup declares it. A mismatch costs shell history and
# leaves the app writing to a tmpfs that vanishes on reboot.
erlinit_mount=$(grep -oE '^-m [^[:space:]]+' rootfs_overlay/etc/erlinit.config | awk '{print $2}')
want_mount="${APP_DEVPATH}:${APP_TARGET}:${APP_FSTYPE}:nodev:nodiscard"
[ "$erlinit_mount" = "$want_mount" ] \
    && ok "erlinit mounts $erlinit_mount" \
    || fail "erlinit mounts '$erlinit_mount' but fwup declares '$want_mount'"

# The DTB named in extlinux must be the one the kernel build installs, which
# Buildroot derives from the DTS filename.
dts_base=$(basename linux/sun50i-h700-anbernic-rg40xx-v.dts .dts)
for f in rootfs_overlay/boot/extlinux/extlinux-a.conf rootfs_overlay/boot/extlinux/extlinux-b.conf; do
    if grep -q "fdt /boot/${dts_base}.dtb" "$f"; then
        ok "$(basename "$f") loads ${dts_base}.dtb"
    else
        fail "$(basename "$f") does not load /boot/${dts_base}.dtb"
    fi
done

# Buildroot builds the DTB named by BR2_LINUX_KERNEL_CUSTOM_DTS_PATH.
grep -q "linux/${dts_base}.dts" nerves_defconfig \
    && ok "nerves_defconfig points at ${dts_base}.dts" \
    || fail "nerves_defconfig does not reference linux/${dts_base}.dts"

echo "==> panel firmware"

# The generic panel driver builds a firmware filename out of the first
# compatible string in the panel node: panels/<compatible>.panel. Nothing
# checks this at build time, and getting it wrong is close to undebuggable on
# device -- the panel simply never initialises, with no error, because
# request_firmware() failing is not fatal to the rest of the pipeline. So
# assert the two spellings match here, where it costs nothing.
# Anchor on the generic fallback rather than on "anbernic," alone -- the board
# node's own compatible starts with "anbernic,rg40xx-v" and would otherwise
# match first.
panel_compat=$(awk '/panel-mipi-dpi-spi/ && /compatible/ {
        match($0, /"anbernic,[^"]+"/)
        if (RSTART > 0) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    }' linux/sun50i-h700-anbernic-rg40xx-v.dts)

if [ -z "$panel_compat" ]; then
    fail "no anbernic panel compatible found in the board DTS"
else
    blob="rootfs_overlay/lib/firmware/panels/${panel_compat}.panel"
    [ -f "$blob" ] \
        && ok "panel '$panel_compat' has its blob at $blob" \
        || fail "panel '$panel_compat' has no blob at $blob"
fi

# The blob is also linked into the kernel image, and CONFIG_EXTRA_FIRMWARE
# names it as a literal string in the fragment. Nothing connects that string
# to the DTS, so switching panel variants in the device tree without editing
# the fragment produces a kernel that embeds the wrong description -- and the
# failure is a dark panel with no error, because the driver is built in and
# request_firmware() is satisfied by the built-in table with the wrong file.
if [ -n "$panel_compat" ]; then
    want="panels/${panel_compat}.panel"
    grep -q "^CONFIG_EXTRA_FIRMWARE=\"${want}\"$" linux/nerves.fragment \
        && ok "CONFIG_EXTRA_FIRMWARE embeds ${want}" \
        || fail "CONFIG_EXTRA_FIRMWARE does not embed ${want} -- the DTS selects
             '$panel_compat' but the fragment embeds
             $(grep '^CONFIG_EXTRA_FIRMWARE=' linux/nerves.fragment || echo 'nothing')"
fi

# The directory the patch copies from must be the one the blob is in, or the
# kernel build embeds nothing and says so only as a build error.
grep -q 'BR2_LINUX_KERNEL_EXTRA_FIRMWARE_DIR="\${NERVES_DEFCONFIG_DIR}/rootfs_overlay/lib/firmware"' nerves_defconfig \
    && ok "the firmware directory points at rootfs_overlay/lib/firmware" \
    || fail "BR2_LINUX_KERNEL_EXTRA_FIRMWARE_DIR does not point at rootfs_overlay/lib/firmware"

# Both variants ship regardless of which one is selected: the wrong one is
# unusable on the wrong hardware, and a blank screen is a poor way to find
# that out. Switching variants should be a one-line DTS change and nothing
# more.
for v in anbernic,rg40xx-panel anbernic,rg40xx-v2-panel; do
    [ -f "rootfs_overlay/lib/firmware/panels/${v}.panel" ] \
        && ok "variant blob present: ${v}.panel" \
        || fail "variant blob missing: ${v}.panel"
done

# fbcon is the only console this board has. Losing console=tty0 would silently
# take the screen back out of the boot path.
for f in rootfs_overlay/boot/extlinux/extlinux-a.conf rootfs_overlay/boot/extlinux/extlinux-b.conf; do
    grep -q 'console=tty0' "$f" \
        && ok "$(basename "$f") puts the kernel log on the panel" \
        || fail "$(basename "$f") is missing console=tty0"
done

# The display stack is built in and the panel description is embedded.
#
# Built in only works together with CONFIG_EXTRA_FIRMWARE. Without it, a
# built-in panel driver calls request_firmware() during initcalls -- before
# the rootfs is mounted -- and fails with -2, leaving no /sys/class/drm/card0
# at all; established on hardware, not guessed. CONFIG_EXTRA_FIRMWARE links
# the blob into the kernel image so request_firmware() is answered from the
# built-in table with no filesystem involved: "cannot be built in" is really
# "cannot be built in while the firmware lives on the rootfs".
#
# It has to be the whole stack, not just the panel: Kconfig silently demotes a
# =y symbol whose subsystem is =m, so CONFIG_DRM_PANEL_MIPI=y alone came back
# out of olddefconfig as =m -- which would have built a module that nothing
# loads, since this panel cannot autoload (the SPI modalias comes from the
# panel's own compatible string, not the driver's). A dark screen with no
# error.
if grep -q '^CONFIG_DRM_PANEL_MIPI=y' linux/linux-6.18.defconfig; then
    ok "the panel driver is built in"
else
    fail "CONFIG_DRM_PANEL_MIPI must be =y, with its blob in CONFIG_EXTRA_FIRMWARE."
    fail "As a module nothing loads it: it cannot autoload, and erlinit does not"
    fail "modprobe it. Check CONFIG_DRM is =y too -- Kconfig demotes it silently."
fi

if grep -q '^CONFIG_DRM=y' linux/linux-6.18.defconfig; then
    ok "DRM is built in, so the panel is allowed to be"
else
    fail "CONFIG_DRM is not =y. Kconfig will demote CONFIG_DRM_PANEL_MIPI=y to =m"
    fail "without saying so, and the panel will never probe."
fi

# The modprobe is gone, and its absence is now the invariant: there is no
# module to load, so the line would only produce a confusing error at boot.
if grep -q '^--pre-run-exec .*modprobe panel-mipi' rootfs_overlay/etc/erlinit.config; then
    fail "erlinit still modprobes panel-mipi, but the driver is built in now."
    fail "There is no module; this only logs an error before the BEAM starts."
else
    ok "erlinit does not modprobe the panel, which is built in"
fi

echo "==> boot logo"

# The logo path in nerves_defconfig is another content-by-path trap: Buildroot
# dereferences it at kernel build time, so a missing or renamed file fails
# three hours in, and a strip narrower than 317 px silently comes up as
# multiple copies (fbcon draws n copies where n*(width+8)-8 <= xres; the
# panel is 640 wide). The PNG width is bytes 16-19 of the IHDR, so no image
# tooling is needed to assert it.
LOGO_REL=$(sed -n 's|^BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH="${NERVES_DEFCONFIG_DIR}/\(.*\)"$|\1|p' nerves_defconfig)

if [ -n "$LOGO_REL" ]; then
    if [ -f "$LOGO_REL" ]; then
        ok "boot logo exists at $LOGO_REL"
        width=$(od -An -tu1 -j16 -N4 "$LOGO_REL" | awk 'NF==4 {print ($1*16777216)+($2*65536)+($3*256)+$4; exit}')
        if [ "${width:-0}" -ge 317 ]; then
            ok "boot logo is ${width}px wide, so fbcon draws it once (needs >316 on 640)"
        else
            fail "boot logo is ${width:-unreadable}px wide; below 317 fbcon draws multiple copies"
        fi
    else
        fail "nerves_defconfig names boot logo $LOGO_REL, which does not exist"
    fi
fi

echo "==> external toolchain"

# The failure this catches shipped in the first commit and survived every build
# since: nerves_defconfig asked for the Nerves toolchain by URL and got Arm's,
# because BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y was missing.
#
# Buildroot's toolchain choice puts the architecture's vendor toolchain first
# and keeps "custom" last, on purpose, so the choice has a default and it is
# not ours. CUSTOM_PREFIX, CUSTOM_GLIBC, HEADERS_* and URL exist only under
# CUSTOM -- without it Kconfig discards them silently and resolves to Arm.
# There is no warning, the build succeeds, and the image is built by a
# different compiler against a different libc than this file claims.
#
# So assert the implication rather than the symbol: anything that only makes
# sense under CUSTOM requires CUSTOM.
DEFCONFIG=nerves_defconfig

custom_only=$(grep -cE '^BR2_TOOLCHAIN_EXTERNAL_(CUSTOM_PREFIX|CUSTOM_GLIBC|CUSTOM_UCLIBC|CUSTOM_MUSL|URL|HEADERS_)' "$DEFCONFIG" || true)

if [ "$custom_only" -gt 0 ]; then
    if grep -q '^BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y$' "$DEFCONFIG"; then
        ok "$custom_only custom-toolchain settings are backed by BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y"
    else
        fail "$DEFCONFIG sets $custom_only BR2_TOOLCHAIN_EXTERNAL_CUSTOM_* / _URL / _HEADERS_* options"
        fail "but not BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y, so Kconfig will ignore all of them"
        fail "and silently build with the architecture's default vendor toolchain."
    fi

    # CUSTOM also requires the compiler version to be declared; without it the
    # toolchain is accepted and Buildroot guesses wrong about what it supports.
    if grep -qE '^BR2_TOOLCHAIN_EXTERNAL_GCC_[0-9]+=y$' "$DEFCONFIG"; then
        ok "the external toolchain's gcc version is declared"
    else
        fail "BR2_TOOLCHAIN_EXTERNAL_CUSTOM needs a BR2_TOOLCHAIN_EXTERNAL_GCC_<n>=y"
    fi

    # The prefix in the URL and the prefix Buildroot is told to use have to
    # match, or the toolchain unpacks and no compiler is found under it.
    url_prefix=$(sed -n 's/^BR2_TOOLCHAIN_EXTERNAL_URL=.*nerves_toolchain_\([a-z0-9_]*\)-.*/\1/p' "$DEFCONFIG")
    declared=$(sed -n 's/^BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="\(.*\)"$/\1/p' "$DEFCONFIG")
    if [ -n "$url_prefix" ] && [ -n "$declared" ]; then
        if [ "$url_prefix" = "$(echo "$declared" | tr - _)" ]; then
            ok "the toolchain URL and CUSTOM_PREFIX describe the same triple ($declared)"
        else
            fail "toolchain URL names '$url_prefix' but CUSTOM_PREFIX is '$declared'"
        fi
    fi
fi

echo "==> dram type"

# The one setting in this repository whose wrong value produces a device with
# no console, no LED and no FEL -- indistinguishable from dead hardware.
# Upstream's anbernic_rg35xx_h700_defconfig says LPDDR4; this board is LPDDR3,
# established from the vendor boot0 (tools/dram-type.sh, docs/bring-up.md).
# Anyone reconciling this file with upstream would flip it back, and the build
# would succeed.
UBOOT=uboot/uboot.defconfig

if grep -q '^CONFIG_SUNXI_DRAM_H616_LPDDR3=y$' "$UBOOT"; then
    ok "U-Boot is configured for LPDDR3"
else
    fail "$UBOOT does not set CONFIG_SUNXI_DRAM_H616_LPDDR3=y"
    fail "This board is LPDDR3. LPDDR4 timings hang the SPL in DRAM init."
fi

if grep -q '^CONFIG_SUNXI_DRAM_H616_LPDDR4=y$' "$UBOOT"; then
    fail "$UBOOT sets CONFIG_SUNXI_DRAM_H616_LPDDR4=y -- that hangs this SoC"
fi

# The type alone is not enough: the drive-strength, ODT and clock values are
# from the same boot0 struct and belong to the same answer. A mixture of
# LPDDR3 type with upstream's LPDDR4 values is not a configuration anything
# has run.
dram_expect() { # dram_expect <symbol> <value>
    got=$(awk -F= -v s="$1" '$1==s{print $2}' "$UBOOT")
    if [ "$got" = "$2" ]; then
        ok "$1=$2"
    else
        fail "$1 is '${got:-unset}', expected $2 (from the vendor boot0)"
    fi
}

dram_expect CONFIG_DRAM_CLK 672
dram_expect CONFIG_DRAM_SUNXI_DX_ODT 0x06060606
dram_expect CONFIG_DRAM_SUNXI_DX_DRI 0x0d0d0d0d
dram_expect CONFIG_DRAM_SUNXI_CA_DRI 0x1919
dram_expect CONFIG_DRAM_SUNXI_ODT_EN 0x9988eeee

# TPR6 and TPR10 have no Kconfig default, so omitting either makes the build
# stop at an interactive prompt rather than fail -- which in CI reads as a
# hang, not a misconfiguration.
for sym in CONFIG_DRAM_SUNXI_TPR6 CONFIG_DRAM_SUNXI_TPR10; do
    if grep -q "^${sym}=" "$UBOOT"; then
        ok "$sym is set, so Kconfig will not prompt"
    else
        fail "$sym has no Kconfig default; without it the build waits for input"
    fi
done

# The DRAM rail is set in two files and both have to agree. The SPL programs
# the PMIC before DRAM training, so uboot.defconfig decides what training runs
# at; the device tree decides what Linux leaves the rail at, and the inherited
# node pins min == max with regulator-always-on, so it really does force it.
#
# Raising one without the other trains at one voltage and runs at another, which
# is worse than either value alone and produces nothing observable -- no hang,
# no log, just a rail 100 mV from where training happened. Exactly the shape
# this file exists to catch.
DTS=linux/sun50i-h700-anbernic-rg40xx-v.dts

spl_mv=$(awk -F= '$1=="CONFIG_AXP_DCDC3_VOLT"{print $2}' "$UBOOT")

# The override is addressed by path, and both properties must carry the same
# value -- a min/max pair that disagrees would be a range the kernel could move
# within rather than the pin this assumes.
dts_uv=$(awk '/dcdc3\}/,/^};/' "$DTS" | sed -n 's/.*regulator-min-microvolt = <\([0-9]*\)>.*/\1/p')
dts_max=$(awk '/dcdc3\}/,/^};/' "$DTS" | sed -n 's/.*regulator-max-microvolt = <\([0-9]*\)>.*/\1/p')

if [ -z "$spl_mv" ]; then
    fail "CONFIG_AXP_DCDC3_VOLT is not set in $UBOOT"
elif [ -z "$dts_uv" ] || [ -z "$dts_max" ]; then
    fail "$DTS does not override dcdc3's min and max microvolts"
    fail "so Linux keeps the value inherited from rg35xx-plus.dts, whatever it is"
elif [ "$dts_uv" != "$dts_max" ]; then
    fail "dcdc3 min ($dts_uv) and max ($dts_max) differ; this check assumes a pin"
elif [ "$(( spl_mv * 1000 ))" -eq "$dts_uv" ]; then
    ok "vdd-dram is ${spl_mv} mV in both the SPL and the device tree"
else
    fail "vdd-dram disagrees: SPL trains at ${spl_mv} mV, the DTS pins $((dts_uv / 1000)) mV"
    fail "Training at one voltage and running at another is worse than either."
fi

echo "==> firmware validation"

# Revert protection depends on exactly one variable here, nerves_fw_validated,
# because U-Boot is built without the bootcount feature and nerves_init reads
# nothing else. But Nerves.Runtime.firmware_validation_status/0 consults
# upgrade_available *first* and treats "0" as validated. So writing
# upgrade_available on a system that does not use bootcount latches automatic
# validation off after the first validation: the application believes every
# later upgrade is already valid, nerves_fw_validated stays 0, and U-Boot
# reverts on the next boot. Confirmed on hardware.
if grep -qi 'CONFIG_BOOTCOUNT' uboot/uboot.defconfig; then
    ok "U-Boot has bootcount enabled, so upgrade_available is meaningful"
elif grep -q 'uboot_setenv(uboot-env, "upgrade_available"' fwup-ops.conf; then
    fail "fwup-ops.conf sets upgrade_available, but U-Boot has no bootcount"
    fail "support. That disables automatic validation after the first validate"
else
    ok "no upgrade_available written, so validation status follows nerves_fw_validated"
fi

# And the upgrade tasks clear the stale variables, so a device that was already
# latched by an older build repairs itself on the next upgrade.
if [ "$(grep -c 'uboot_unsetenv(uboot-env, "upgrade_available")' fwup.conf)" -eq 2 ]; then
    ok "both upgrade tasks clear leftover bootcount variables"
else
    fail "upgrade.a and upgrade.b must both unset upgrade_available, or a device"
    fail "latched by an older build never validates automatically again"
fi

echo
if [ "$rc" -eq 0 ]; then echo "Image layout is self-consistent"; else echo "CONSISTENCY CHECK FAILED"; fi
exit $rc
