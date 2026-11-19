# Flashing

Replaces Google's firmware with the image from [`README.md`](README.md), signed
with your keys, and leaves the machine in normal (verified) mode. This is the
procedure that was followed on one spherion. It is hands-on throughout; allow
two hours the first time.

**You can end up with a machine that does not boot.** The way back is the stock
image you saved, written over the debug cable. Do not start without both.

## What you need

- A **SuzyQable** (ChromeOS closed-case debugging cable).
- A **second computer** to flash from, with `flashrom` 1.4 or newer (it needs
  the `raiden_debug_spi` programmer), a serial terminal such as `picocom`, and
  `futility` (vboot-utils). A Raspberry Pi is enough.
- The machine in **developer mode**, running Linux, with `gsctool` and
  `futility` installed.

Never write the AP flash over the cable from the machine itself with the cable
looped back into its own USB port. The Cr50 holds the AP in reset while the
flash is written, which kills the process doing the writing.

With the cable on the second computer, three serial consoles appear:
`/dev/ttyUSB0` is the Cr50, `ttyUSB1` the AP, `ttyUSB2` the EC. (On the machine
itself they need `CONFIG_USB_SERIAL_SIMPLE`.)

## Before the day

- [ ] **Back up the stock firmware.** Read it twice, compare, keep it off the
      machine: `flashrom -p linux_mtd -r stock-1.bin` from the running system,
      or over the cable as in step 4.
- [ ] Keys created, and the image built and re-keyed (`rekey.sh`).
- [ ] **A kernel partition signed with your kernel key is installed and marked
      good.** Developer mode boots it already; normal mode with your firmware
      will boot nothing else. Check with `depthchargectl list`: the partition
      you are running must show as successful.
- [ ] A rescue plan that works in normal mode. A USB stick boots in normal mode
      only as a recovery image, so it must be signed with your *recovery* kernel
      key (`recovery_kernel.keyblock`, `recovery_kernel_data_key.vbprivk`). A
      developer-key stick stops being bootable the moment you flash.
- [ ] Every encrypted volume has a passphrase keyslot you have tested. Step 1
      wipes the TPM.
- [ ] The machine on its charger, on the USB-C port the cable is not using.

## 1. Open CCD (on the machine)

```
sudo gsctool -a -o
```

Press the power button each time the prompt asks, for about five minutes.
**This wipes the TPM**, and with it any disk keys enrolled there.

Check: `sudo gsctool -a -I` shows `State: Opened`.

Two things to expect. The wipe also turns developer mode off. And from here
until the new firmware is written the machine cannot boot at all: Google's
firmware in normal mode rejects a kernel signed with your key. Do not stop
half way.

## 2. Turn off write protection (second computer)

```
sudo picocom -b 115200 /dev/ttyUSB0      # Cr50 console; leave with Ctrl-A Ctrl-X
> wp false atboot
> wp                                      # "Flash WP: forced disabled"
sudo flashrom -p raiden_debug_spi:target=AP --wp-disable
sudo flashrom -p raiden_debug_spi:target=AP --wp-status
```

## 3. Read what is on the chip

```
sudo flashrom -p raiden_debug_spi:target=AP -r current-1.bin
sudo flashrom -p raiden_debug_spi:target=AP -r current-2.bin
```

Every flashrom run over the cable resets the AP, so the machine may boot in
between and rewrite its own runtime regions. Two reads can therefore differ
legitimately, but only inside `RW_NVRAM`, `RW_MRC_CACHE` and `RW_ELOG`. Map any
differing offsets to regions (`futility dump_fmap current-1.bin`) and stop if
anything else differs.

## 4. Prepare the image

```
firmware/prepare-flash.sh current-1.bin image-spherion.bin flash.bin
```

It carries this machine's VPD, NVRAM, event log and HWID over into the new
image, sets GBB flags 0, and checks both RW slots against the root key now in
the image. The regions it reports as changing should be the read-only section
and GBB, both RW slots, `RW_MRC_CACHE` and `RW_LEGACY`.

## 5. Write

```
sudo flashrom -p raiden_debug_spi:target=AP -w flash.bin
```

About three and a half minutes. flashrom verifies as part of `-w`. A separate
`-v` afterwards can report a mismatch for the reason given in step 3; check
which regions before believing it. If the write itself fails, write the stock
backup the same way.

## 6. First boot

Press the power button. **The first boot is slow.** The memory training cache
was replaced, so DRAM calibrates again, and the EC is updated to the RW image
you built and restarts once. Give it two minutes.

```
crossystem fwid ro_fwid              # your FWID
crossystem mainfw_type               # normal
crossystem devsw_boot                # 0
crossystem kernkey_vfy               # sig
```

`kernkey_vfy` reading `sig` is the proof: the firmware verified the kernel's
signature against your key. In developer mode it reads `hash`.

If it does not boot, write the stock backup from the second computer and start
again from a known state.

## 7. Check the fallback

Both RW slots hold the same firmware. Boot the other one once:

```
sudo crossystem fw_try_next=B fw_try_count=1 && sudo reboot
crossystem mainfw_act                # B
```

`crossystem` prints `Failed to disable write-protection, MEMUNLOCK ioctl
returned -1` when it writes. The value is written regardless: `linux_mtd` cannot
do the write-protect ioctl, and `RW_NVRAM` is not protected. Read the field back
instead of trusting the message.

## 8. Re-arm write protection (second computer)

```
sudo flashrom -p raiden_debug_spi:target=AP --wp-range=0,0x400000 --wp-enable
sudo picocom -b 115200 /dev/ttyUSB0
> wp true atboot
```

Then check from the machine that a write to the read-only half through
`linux_mtd` is refused while `crossystem` still works.

Record PCR0 and PCR1 now if you are going to use the disk unlock
(`tpm2_pcrread sha256:0,1`). They are stable across reboots in normal mode, and
they change if you go back to developer mode or change the HWID.

## Updating later: RW only

A later firmware build only needs the two RW sections written, which leaves the
write-protected half, the HWID, the VPDs and the runtime state alone, and needs
no `prepare-flash.sh`:

```
sudo flashrom -p raiden_debug_spi:target=AP --fmap -i RW_SECTION_B -w image-spherion.bin
```

then boot slot B once on a single try (step 7), and only when it has booted
write `RW_SECTION_A` the same way. Until then slot A is the last good copy.

`--fmap` is what lets flashrom resolve region names; without it `-i` fails with
"no layout data is available". Afterwards `ro_fwid` and `fwid` differ, because
the read-only section still carries the first build. That is expected.

Writing the AP flash over the cable needs CCD open (`FlashAP` is `IfOpened` by
default), and CCD does not stay open forever: on the development machine it was
found locked again some days later. Opening it again wipes the TPM again. Plan
firmware updates so that they share one CCD session, and expect to enrol the
disk keys again afterwards.

## Things that are easy to get wrong

- **Do not use the "hold Power, press Refresh repeatedly" key combination**
  after flashing your own read-only firmware. Cr50 firmware has an AP RO
  verification feature tied to that combination, checked against a hash stored
  at the factory, which a self-built RO cannot match. What it does on a failed
  check was not tested here.
- **`crossystem` needs a vboot-utils that can reach the flash.** It runs
  `flashrom -p host`, a programmer only ChromiumOS's flashrom fork has. With
  upstream flashrom, build vboot-utils with the programmer set to
  `linux_mtd:dev=0`; otherwise NVRAM-backed fields read as `(error)`.
- **`futility dump_fmap` cannot read `/dev/mtd0` directly.** Dump the flash to a
  file first.
- **Keep images out of `/tmp` if it is a tmpfs.** The A/B test reboots the
  machine, and an image parked there is gone when you want to restore it.
- **With the debug cable in one USB-C port the machine may charge only at 5 V
  through it**, and drain while you work. Charge on the other port.
- **A black screen is not proof of a failed boot.** A machine that booted a
  kernel without its display driver looks exactly like one that did not boot.
  The AP console says which.
