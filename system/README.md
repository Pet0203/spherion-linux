# Userspace glue for `dm-mod.create=` volumes under systemd

Devices mapped by the kernel from its command line exist before udev does, and
udev's device-mapper rules were written for devices created by libdevmapper
while udev is watching. Three things follow. The root filesystem escapes all of
them, because the kernel mounts it by name without asking anyone; every other
volume (a separate `/home`, here) does not.

This was worked out on Arch Linux ARM with systemd 261. Each fix was verified by
rebooting and watching for unmount events.

## 1. Nobody announces the devices

udev ignores `add` events for device-mapper and acts only on `change`, and the
one `change` event these devices produced happened before udev started. Result:
no `/dev/mapper/<name>`, no `/dev/disk/by-uuid` link, no `.device` unit, and a
mount that waits ninety seconds and fails.

Install [`swifty-dm-announce.service`](swifty-dm-announce.service) to
`/etc/systemd/system/` and enable it, and
[`systemd-udev-trigger.service.d/10-dm-init-change.conf`](systemd-udev-trigger.service.d/10-dm-init-change.conf)
as a drop-in for `systemd-udev-trigger.service`. Both send the missing `change`
event; the first does it early enough not to cost boot time, the second is a
fallback.

## 2. Coldplug then takes them away again

The replayed `add` event sends such a device down the "not really activated"
branch of `10-dm.rules`, because it has no libdevmapper cookie. That sets
`DM_UDEV_DISABLE_DISK_RULES_FLAG`, `13-dm-disk.rules` stops maintaining the
`by-uuid` link, the device unit goes inactive, and systemd unmounts the
filesystem: an fstab mount is stopped when its backing device unit stops. On
the development machine `/home` mounted at 1.1 s and was unmounted 0.8 s later,
with no failed unit and no error. It does not recover by itself, because the
flags are re-imported from the udev database on every later event.

The fix is a udev rule that sorts before `10-dm.rules` and sets
`DM_UDEV_PRIMARY_SOURCE_FLAG=1` on `add` events for these devices, so that
`10-dm.rules` treats them as genuinely active. The rule file from the
development machine is not reproduced here; write it for your device names.

## 3. fstab

For each such volume other than root:

- mount `/dev/mapper/<name>`, not `UUID=`. That link is made by `10-dm.rules`
  itself and survives what happens to the `by-uuid` one;
- add `x-systemd.device-bound=false`, so the mount is not stopped when the
  device unit flaps;
- if you skip fsck at boot (`fsck.mode=skip` on the command line), set the fsck
  pass number to 0. Otherwise the mount still depends on a
  `systemd-fsck@` unit that is itself bound to the device, and the stop travels
  through it.

With all three in place: no unmount events across reboots.
