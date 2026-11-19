# Kernel

Six patches against Linux v7.3 (`c03c1a14507d`). Each file is `git am` ready
and carries its full explanation in its header; this page is the overview and
the test record.

```
cd linux
git checkout v7.3
git am /path/to/kernel/patches/*.patch
```

| # | Patch | For | Upstream state (2026-11) |
|---|---|---|---|
| 1 | dts: mt8192-asurada: disable the SCP's cros-ec-rpmsg node | suspend | not upstream; empirical |
| 2 | spi: mtk-nor: re-initialise the controller in runtime resume | suspend | not upstream |
| 3 | drm/panfrost: unprepare the GPU clocks across system suspend | suspend | not upstream. v7.4 reworks this code, so the patch does not apply there, but still leaves the PLL prepared; see the patch header |
| 4 | drm/bridge: anx7625: register Type-C mode switches | USB-C DP | never merged; adapted from ChromeOS |
| 5 | dts: mt8192-asurada: enable USB-C DisplayPort output | USB-C DP | not upstream; needs 4 |
| 6 | dm: take dm-crypt keys handed over by the firmware | disk unlock | not upstream; needs the firmware in this repository |

Patches 1 to 3 stand alone. Patch 5 without patch 4 breaks USB-C entirely
(`cros_ec_typec` then defers its probe forever), so take both or neither.
Patch 6 does nothing without the patched depthcharge, and is safe to leave out.

## Suspend

Symptoms on an unpatched mainline kernel, and what fixed each:

- **The machine wakes by itself a few seconds after suspending**, and the EC
  logs `Detected sleep hang! Waking host up!`. The EC waits for the SoC to
  assert `AP_IN_SLEEP_L`, which only happens when the SoC reaches its deep
  suspend state, and that needs the 26 MHz bus clock to be releasable. The GPU's
  PLL was left running across suspend and held it. Patch 3.
- **Resume hangs with a black screen.** The SPI NOR controller's resume path
  writes registers while its clocks are gated. Patch 2, together with patch 1.

Patch 1 is the least understood of the three: it disables a device-tree node,
the hang went away, and the reason was not pinned down. Its header says what is
and is not known.

The EC's console over a SuzyQable is what made the first problem visible. If
suspend misbehaves on a related board, watch that console while suspending:
the EC says what it is waiting for.

### How it was tested

- `mem_sleep` is `deep`.
- On the kernel in daily use (7.3-rc4 plus these patches):
  `/sys/power/suspend_stats/success` 29, `fail` 0, after 18 days of uptime,
  with sleeps from a few seconds to eleven hours.
- An earlier controlled run on 7.3-rc3: 10 of 10 resumes with the display back,
  the SPI NOR back in runtime PM `auto` and readable with
  `flashrom -p linux_mtd` after each.

On battery the LED shows it: blue while the machine runs, blinking amber (one
second on, three off) while it is suspended. With the charger connected the
LED shows the charge state instead, amber while charging and blue when full,
asleep or not, so it cannot tell you then. To check independently of the LED,
compare `CLOCK_BOOTTIME` with `CLOCK_MONOTONIC` before and after; the
difference grows by the time spent asleep.

The command line used is in [`cmdline.example`](cmdline.example). It carries
`fw_devlink=rpm driver_async_probe=none deferred_probe_timeout=2 noresume`.
Which of those suspend actually needs was not isolated.

## USB-C DisplayPort

The SoC's DPI output feeds a second ANX7625 bridge (separate from the one that
drives the internal panel), whose crosspoint switch routes the DisplayPort lanes
to either USB-C port. The EC negotiates DP alternate mode and hot-plug detect by
itself; what was missing in mainline is the device-tree description of that
path and the driver support for choosing the port. Patches 4 and 5.

With both applied, a `DP-1` connector appears under `/sys/class/drm`, and two
muxes, `7-0058-switch0-mux` and `7-0058-switch1-mux`, under
`/sys/class/typec_mux`.

Known limits and issues:

- **1920x1080 at 60 Hz is the ceiling.** DPI0 on MT8192 is limited to a 150 MHz
  pixel clock, so higher modes are never offered. This is the hardware.
- **Stable at 1080p30, not at 1080p60.** Through a USB-C hub (VIA VL817 based)
  to a 1440p monitor, 1920x1080 at 60 Hz showed artifacts and horizontal
  jitter, while 1920x1080 at 30 Hz gave a stable picture. The same picture at
  60 Hz needs a 148.5 MHz pixel clock, right at the 150 MHz limit, and at 30 Hz
  half of that, 74.25 MHz, so the problem appears to grow with the pixel clock;
  that is an inference, not something that was measured. The device tree, pin
  configuration and the DPI and bridge settings were compared with the
  ChromeOS 6.1 kernel and found the same, so the cause is still open. During
  the 60 Hz test a debug cable occupied the other USB-C port. No direct USB-C
  to DisplayPort cable or second monitor was tried. Reports from other setups
  would be useful.
- The second bridge logs two I2C errors when it probes
  (`fail to access i2c id=3f`). Their relation to the above is unknown.
- **Tested only with the kernel's own DP alternate-mode driver kept from
  loading.** The test machine has `blacklist typec_displayport` in
  `/etc/modprobe.d` from earlier experiments. Whether output also works with
  that module loaded was not tried.
- No DisplayPort audio.
- Further driver limitations are listed in patch 4's header.

## Audio

No patch is involved. Speaker, headphones, the internal microphones and a
headset microphone work on the development machine with:

- the mainline machine driver, `mt8192_mt6359_rt1015p_rt5682`:
  `CONFIG_SND_SOC_MT8192=m` and `CONFIG_SND_SOC_MT8192_MT6359_RT1015_RT5682=m`,
  which select the MT6359, RT1015P, RT5682 and DMIC codec drivers;
- the UCM profile shipped in `alsa-ucm-conf` 1.2.16.1
  (`MediaTek/mt8192/mt6359-rt1015p-rt5682`), unmodified;
- PipeWire 1.6 with WirePlumber 0.5, with no configuration of their own.

The card exposes twenty raw PCMs, and without a matching UCM profile a sound
server only offers a "Pro Audio" profile listing all of them. With the profile
it offers "HiFi" with four devices. If you see only "Pro Audio", check that
`alsaucm -c hw:0 list _verbs` finds a `HiFi` verb before looking anywhere else.

## Disk unlock

Patch 6 is the kernel half of the firmware disk unlock described in
[`../docs/disk-unlock.md`](../docs/disk-unlock.md). It needs:

```
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_CRYPT=y
CONFIG_DM_INIT=y
CONFIG_DM_BOOT_KEYS=y
```

all built in, not as modules, since they have to work before any filesystem is
mounted, along with whatever your cipher needs (`CONFIG_CRYPTO_XTS=y` and
`CONFIG_CRYPTO_AES_ARM64_CE_BLK=y` for `aes-xts-plain64`) and the drivers for
the disk itself (`CONFIG_MMC_MTK=y` here).

## Configuration

[`config/spherion-7.3-rc4.config`](config/spherion-7.3-rc4.config) is the
complete configuration of the kernel in daily use, taken from the running
machine, with `CONFIG_LOCALVERSION` emptied. It is a reference, not a
recommendation. Things to know before copying it:

- It is built with clang (`LLVM=1`) and turns on CFI, ThinLTO, shadow call
  stacks, forced module signatures and kernel lockdown. None of that is needed
  for anything in this repository.
- It has no initramfs support (`CONFIG_BLK_DEV_INITRD` is off) and builds the
  eMMC and ext4 drivers in. The internal panel's bridge (`anx7625`) and Wi-Fi
  (`mt7921e`) are modules.
- **`CONFIG_STATIC_USERMODEHELPER=y` with a helper path that does not exist.**
  As configured, the kernel cannot run `modprobe` itself, so nothing is loaded
  on demand: every module has to be loaded by udev or listed in
  `/etc/modules-load.d`. Symptoms are silent and odd (an nftables `ct` rule
  failing with ENOENT, a Bluetooth headset without a microphone). Turn the
  option off unless you provide the helper.
- It embeds firmware files (`CONFIG_EXTRA_FIRMWARE`) for the SCP, Wi-Fi and
  Bluetooth, which have to exist in `/lib/firmware` at build time.
- `CONFIG_USB_SERIAL_SIMPLE=m` is what makes a SuzyQable's three consoles show
  up as `/dev/ttyUSB0` to `2`.

## Building a kernel partition

depthcharge boots a signed "kernel partition": a FIT image holding the kernel
and the device tree, wrapped with a command line and a signature.
[`build-kpart.sh`](build-kpart.sh) makes one and signs it with your own kernel
key:

```
KEYDIR=/path/to/keys/signing kernel/build-kpart.sh \
    arch/arm64/boot/Image \
    arch/arm64/boot/dts/mediatek/mt8192-asurada-spherion-r0.dtb \
    my-cmdline out.kpart
```

Run against the same kernel, it produces a partition whose FIT has the same
layout and byte-identical kernel and device-tree contents as the one booting
the development machine.

In developer mode any validly self-signed partition boots, so `depthchargectl`
from depthcharge-tools with its default keys is all you need. Your own keys
only matter once the firmware is yours as well, and then two things bite:

- **`depthchargectl` verifies images against the keys it is configured with**
  and refuses to write one signed with yours ("not signed by the configured
  keys"). Point it at your kernel subkey with `vboot-public-key = ...` under
  `[depthcharge-tools]` in `/etc/depthcharge-tools/config`.
- **A kernel that has booted but was never marked good cannot boot again.**
  vboot clears a partition's priority and tries as it boots it on its last try.
  Run `depthchargectl bless` once a new kernel has proven itself, and never
  write the second partition while the running one is unblessed, or the next
  reboot finds nothing bootable.

Also worth knowing if the fallback slot is meant to be usable: upgrading a
kernel package removes the old kernel's modules while the old kernel image is
still in the other partition. With the panel bridge and Wi-Fi built as modules,
that fallback boots to a black screen with no network, which looks exactly like
a machine that did not boot. Keep the previous kernel's module directory.
