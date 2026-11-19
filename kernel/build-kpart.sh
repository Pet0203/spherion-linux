#!/usr/bin/env bash
# Assemble and sign a ChromeOS kernel partition for depthcharge from a kernel
# Image, a device tree and a command line file, with your own vboot keys.
#
# The recipe is depthcharge-tools' mkdepthcharge for a FIT image with no
# initramfs, written out so that the machine holding the keys needs nothing but
# mkimage, fdtput and futility: a FIT holding the uncompressed kernel and the
# board's device tree, the kernel node retyped to kernel_noload, wrapped and
# signed by vbutil_kernel.
#
# Usage: build-kpart.sh IMAGE DTB CMDLINE_FILE OUTPUT.kpart
#
#   IMAGE         arch/arm64/boot/Image (uncompressed)
#   DTB           e.g. arch/arm64/boot/dts/mediatek/mt8192-asurada-spherion-r0.dtb
#   CMDLINE_FILE  the command line; blank lines and lines starting with # are
#                 dropped and the rest joined with spaces (see cmdline.example)
#
# Environment:
#   KEYDIR    directory holding kernel.keyblock, kernel_data_key.vbprivk and
#             kernel_subkey.vbpubk: the signing/ directory from
#             keys/create-keys.sh (required)
#   FUTILITY  futility to use (default: futility from PATH)
#   VERSION   vboot kernel version to sign with (default: 1)
#
# Write the result to a ChromeOS kernel partition with
# "depthchargectl write OUTPUT.kpart" or with dd and cgpt.
set -euo pipefail

IMAGE=${1:?usage: build-kpart.sh IMAGE DTB CMDLINE_FILE OUTPUT.kpart}
DTBFILE=${2:?usage: build-kpart.sh IMAGE DTB CMDLINE_FILE OUTPUT.kpart}
CMDLINE=${3:?usage: build-kpart.sh IMAGE DTB CMDLINE_FILE OUTPUT.kpart}
OUTPUT=${4:?usage: build-kpart.sh IMAGE DTB CMDLINE_FILE OUTPUT.kpart}
KEYDIR=${KEYDIR:?set KEYDIR to the directory holding your kernel signing keys}
FUTILITY=${FUTILITY:-futility}
VERSION=${VERSION:-1}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

"$FUTILITY" version >/dev/null 2>&1 || die "futility ($FUTILITY) does not run on this host"
command -v mkimage >/dev/null || die "mkimage missing (u-boot tools)"
command -v fdtget >/dev/null && command -v fdtput >/dev/null || die "fdtget/fdtput missing (dtc)"
[ -s "$IMAGE" ] || die "no kernel Image: $IMAGE"
[ -s "$DTBFILE" ] || die "no device tree: $DTBFILE"
[ -s "$CMDLINE" ] || die "no command line file: $CMDLINE"
for k in kernel.keyblock kernel_data_key.vbprivk kernel_subkey.vbpubk; do
  [ -r "$KEYDIR/$k" ] || die "cannot read $KEYDIR/$k"
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "kernel  $(basename "$IMAGE") ($(stat -c%s "$IMAGE") bytes)"
echo "dtb     $(basename "$DTBFILE") ($(stat -c%s "$DTBFILE") bytes)"

step "build the FIT"
# -C none: an uncompressed kernel is what has been tested, and mkimage assumes
# gzip unless told otherwise. The description matches what the other sub-images
# get, as mkdepthcharge does.
mkimage -f auto -A arm64 -T kernel -O linux -C none -n unavailable \
  -b "$DTBFILE" -d "$IMAGE" "$WORK/kernel.fit" >/dev/null
# mkimage writes type "kernel"; depthcharge wants "kernel_noload", and passing
# -T kernel_noload to mkimage instead breaks the config node's key.
KNODE=""
for n in $(fdtget -l "$WORK/kernel.fit" /images); do
  [ "$(fdtget -t s "$WORK/kernel.fit" "/images/$n" type 2>/dev/null)" = kernel ] || continue
  KNODE=/images/$n; break
done
[ -n "$KNODE" ] || die "no kernel sub-image in the FIT"
fdtput -t s "$WORK/kernel.fit" "$KNODE" type kernel_noload
echo "fit     $KNODE retyped to kernel_noload, $(stat -c%s "$WORK/kernel.fit") bytes"

step "sign"
# depthcharge substitutes %U with the GUID of the partition it booted.
{ printf 'kern_guid=%%U'
  grep -vE '^[[:space:]]*(#|$)' "$CMDLINE" | while read -r line; do printf ' %s' "$line"; done
  printf '\n'
} > "$WORK/cmdline"
echo "cmdline $(cat "$WORK/cmdline")"
# --bootloader is mandatory but unused on this platform.
head -c 512 /dev/zero > "$WORK/empty.bin"
"$FUTILITY" vbutil_kernel --pack "$OUTPUT" --version "$VERSION" --arch aarch64 \
  --vmlinuz "$WORK/kernel.fit" --config "$WORK/cmdline" --bootloader "$WORK/empty.bin" \
  --keyblock "$KEYDIR/kernel.keyblock" --signprivate "$KEYDIR/kernel_data_key.vbprivk"

step "verify"
# Against a named kernel subkey, so "valid" means signed by that key and not
# just internally consistent, which is all developer mode checks.
SUBKEY=$KEYDIR/kernel_subkey.vbpubk
"$FUTILITY" vbutil_kernel --verify "$OUTPUT" --signpubkey "$SUBKEY" > "$WORK/verify" \
  || { cat "$WORK/verify"; die "the kernel partition does not verify against $SUBKEY"; }
grep -q 'Signature: *valid' "$WORK/verify" || die "keyblock signature not valid against $SUBKEY"
sed -n '1,20p' "$WORK/verify"
echo "verified against $(basename "$SUBKEY") $("$FUTILITY" show "$SUBKEY" | sed -n 's/.*Key sha1sum: *//p')"
echo
sha256sum "$OUTPUT"
