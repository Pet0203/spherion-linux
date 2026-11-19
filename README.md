# Mainline Linux and self-signed firmware on the Acer Chromebook 514 (Spherion)

Patches and tooling for one machine: the Acer Chromebook 514 CB514-2H,
`google,spherion`, MediaTek MT8192 on the "asurada" baseboard. They cover three
things.

1. **Kernel fixes** for mainline Linux: working suspend-to-RAM, and DisplayPort
   output on the USB-C ports.
2. **Your own keys in the firmware.** coreboot, TF-A, depthcharge and the EC's
   RW image built from Google's sources, signed with keys you create, running in
   normal (verified) mode instead of developer mode.
3. **Full-disk encryption without an initramfs.** The firmware asks for a PIN,
   reads the volume keys from the Cr50 security chip and hands them to the
   kernel, which maps the encrypted root from its command line.

The three are independent. The kernel fixes need nothing else from here and are
probably the part most people came for.

"swifty" is the hostname of the machine all this was developed on. It survives
in a few identifiers (the `swifty-enroll` tool, key descriptions such as
`swifty:root`, one string in the firmware) and means nothing more than that.

## What is here

| Path | What |
|---|---|
| [`kernel/patches/`](kernel/patches) | Six patches against Linux v7.3 |
| [`kernel/README.md`](kernel/README.md) | What each patch does, how it was tested, config and command line |
| [`kernel/build-kpart.sh`](kernel/build-kpart.sh) | Builds and signs a kernel partition with your own keys |
| [`firmware/patches/`](firmware/patches) | Patches for coreboot (1), vboot (1) and depthcharge (3) on Google's `firmware-asurada-13885.B` sources |
| [`firmware/README.md`](firmware/README.md) | Building the firmware image from pinned sources |
| [`firmware/FLASHING.md`](firmware/FLASHING.md) | Getting it onto the machine, and what can go wrong |
| [`keys/create-keys.sh`](keys/create-keys.sh) | Creates a vboot key set |
| [`tpm/swifty-enroll`](tpm/swifty-enroll) | Puts the disk keys into the Cr50 |
| [`system/`](system) | The systemd and udev glue an initramfs-less dm-crypt root needs |
| [`docs/disk-unlock.md`](docs/disk-unlock.md) | How the firmware unlock works, and exactly what it does not protect against |

## Status

Everything below was measured on one machine: spherion rev3, 8 GB, Cr50 (H1)
firmware RW 0.5.241, stock firmware `Google_Spherion.13885.143.0`.

| Area | State |
|---|---|
| Suspend-to-RAM (`deep`) | Works. 29 suspend/resume cycles without a failure over 18 days of uptime on the kernel described here, including overnight sleeps. Needs kernel patches 1 to 3. |
| USB-C DisplayPort | Works, up to 1920x1080 at 60 Hz (a hardware limit). Tested through one USB-C hub with one monitor: stable at 1080p30, artifacts at 1080p60; see [known issues](kernel/README.md#usb-c-displayport). Needs kernel patches 4 and 5. |
| Audio | Works with mainline and stock userspace; nothing from this repository is needed. See [the notes](kernel/README.md#audio). |
| Own firmware, own keys | In daily use in normal mode. Both RW slots and A/B fallback verified, RO write-protection re-armed. |
| Firmware disk unlock | In daily use: PIN on the firmware screen, LUKS2 root and home, no initramfs. Read [the limits](docs/disk-unlock.md#what-this-does-not-protect-against) before relying on it. |

The kernel patches were developed on 7.3-rc kernels and are in use on 7.3-rc4.
The series applies cleanly to v7.3 and builds there.

## Before you flash anything

The firmware part can leave you with a machine that does not boot. It has a way
back only if you prepare one:

- You need a SuzyQable (the ChromeOS closed-case debugging cable) and a second
  computer to flash from. The machine cannot safely reflash itself.
- Read the stock firmware out twice, compare, and keep it somewhere else.
- Opening CCD to flash wipes the TPM. If your disk keys are in it, they are
  gone. Keep a passphrase keyslot on every LUKS volume.

[`firmware/FLASHING.md`](firmware/FLASHING.md) has the whole procedure and the
traps that were hit on the way.

## Provenance and licence

The firmware sources are Google's, at the commits listed in
[`firmware/manifest.yml`](firmware/manifest.yml). No firmware binaries, blobs or
keys are in this repository; the build takes the MediaTek blobs from Google's
public blobs repository and the firmware-screen bitmaps from your own machine's
stock image.

The USB-C DisplayPort kernel patches adapt work by Pin-yen Lin and Prashant
Malani that ChromeOS kernels carry and that was posted for mainline but not
merged; the patches say where.

Much of the code and text in this repository was written with the help of an AI
coding assistant (Claude). What is described as tested was run on the hardware
above; what was not is marked as such.

Each patch is under the licence of the file it changes: GPL-2.0 for Linux,
coreboot and depthcharge, BSD-3-Clause for vboot_reference. Everything else
here is GPL-2.0-only; see [`COPYING`](COPYING).

There is no warranty of any kind. This is one person's working setup, published
because someone asked.
