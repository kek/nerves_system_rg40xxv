# Bluetooth notes

Findings that would otherwise be lost, kept here rather than in
`linux/nerves.fragment` because `linux` is in `package_files()`. A comment
added there changes the artifact checksum and forces a full rebuild for no
functional change — which is exactly what happened once, and cost a flash.

## The firmware blob, and why it was missing

The RTL8821CS needs two files. `rtl8821cs_fw.bin` arrives with
`BR2_PACKAGE_LINUX_FIRMWARE_RTL_88XX_BT`, whose file list is the glob
`rtl_bt/rtl88*.bin`. The config blob does not, and `btrtl` treats it as
mandatory, so setup aborted while `hci0` stayed behind looking healthy.

linux-firmware ships no `rtl8821cs_config.bin` file at all. `WHENCE` declares
it a symlink:

    Link: rtl_bt/rtl8821cs_config.bin -> rtl8761b_config.bin

and Buildroot recreates WHENCE symlinks only where the target was packaged.
`rtl8761b_config.bin` does not match `rtl88*`, so the link was skipped
silently. `BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT` lists that file
explicitly, which is why the 87xx option is enabled for an 88xx chip.

Confirmed on hardware after the fix:

    Bluetooth: hci0: RTL: cfg_sz 25, total sz 36953
    Bluetooth: hci0: RTL: fw version 0x75b8f098

## The controller answers, and the numbers prove the firmware is running

A diagnostic in the application binds an `HCI_CHANNEL_USER` socket to `hci0`
and issues Reset then Read Local Version. On this board:

    manufacturer: 93 (0x5D, Realtek)   hci_version: 8   lmp_version: 8
    hci_revision: 30136 (0x75B8)       lmp_subversion: 61592 (0xF098)

Note that those two revision fields **disagree with what btrtl logged at
boot**, and that the disagreement is the interesting part.

| Field | btrtl, before upload | probe, after |
|---|---|---|
| `hci_revision` | `0x000C` | `0x75B8` |
| `lmp_subversion` | `0x8821` | `0xF098` |

`0x75B8` concatenated with `0xF098` is `0x75B8F098` — exactly the value btrtl
printed as `RTL: fw version 0x75b8f098`. So the controller reports its ROM
identity until it is patched, and its firmware version afterwards.

That makes this the cheapest hard proof available that Bluetooth firmware is
loaded *and running*, as distinct from having been pushed at the chip once at
boot. A live probe returning `0x000C` / `0x8821` would mean the upload had
not taken — the failure this board spent a day on, in a form that
`/sys/class/bluetooth/hci0` existing would never reveal.

## "BT_LE is not set" does not disable Bluetooth Low Energy

`linux/linux-6.18.defconfig:174` carries `# CONFIG_BT_LE is not set`,
inherited from the upstream arm64 defconfig. It reads alarmingly and means
almost nothing here. From `net/bluetooth/Makefile` in the 6.18.44 tree this
system actually builds:

    15  bluetooth-y := af_bluetooth.o hci_core.o hci_conn.o hci_event.o mgmt.o \
    16          hci_sock.o hci_sysfs.o l2cap_core.o l2cap_sock.o smp.o lib.o
    23  bluetooth-$(CONFIG_BT_LE) += iso.o

`hci_sock.o`, `l2cap_core.o` and `smp.o` are unconditional. Only `iso.o` — LE
Audio ISO sockets — hangs off `BT_LE`. LE advertising and connections are
present.

It matters less still for how this device is driven. The application binds an
`AF_BLUETOOTH` `HCI_CHANNEL_USER` socket to `hci0` and speaks raw HCI,
bypassing the kernel's Bluetooth stack entirely. The only kernel code in that path is `hci_sock.c`
plus the `hci_uart`/`btrtl` serdev driver.

So: left alone deliberately, and documented so nobody spends a rebuild
discovering the same thing.

## No BlueZ, on purpose

There is no BlueZ in the image — no `hciconfig`, `bluetoothctl`, `btmgmt` or
`btattach`. The application talks HCI directly rather than pulling in D-Bus, and the
probe above is what confirms the controller *answers*, as distinct from having
had firmware uploaded to it at boot.
