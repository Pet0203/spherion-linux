#!/usr/bin/env bash
# Turn a firmware image into one that trusts your keys: your root and recovery
# keys and GBB flags 0 in the GBB, both RW slots re-signed with your firmware
# keyblock and data key, and your kernel subkey in their preambles.
#
# This is how ChromeOS's own signers re-key images, and it leaves everything
# else untouched: re-signing the dev-key image from build.sh with the dev keys
# this way reproduces it byte for byte.
#
# PUBLIC_DIR and SIGNING_DIR are the public/ and signing/ directories that
# keys/create-keys.sh writes.
#
# Usage: rekey.sh IN.bin OUT.bin PUBLIC_DIR SIGNING_DIR
#   PUBLIC_DIR   root_key.vbpubk, recovery_key.vbpubk
#   SIGNING_DIR  firmware.keyblock, firmware_data_key.vbprivk, kernel_subkey.vbpubk
set -euo pipefail

IN=${1:?usage: rekey.sh IN.bin OUT.bin PUBLIC_DIR SIGNING_DIR}
OUT=${2:?}
PUB=${3:?}
SIG=${4:?}
FUTILITY=${FUTILITY:-futility}
VERSION=1

die() { echo "error: $*" >&2; exit 1; }
sha1_of() { "$FUTILITY" show "$1" | sed -n 's/.*Key sha1sum: *//p' | head -1; }

for f in "$PUB/root_key.vbpubk" "$PUB/recovery_key.vbpubk" "$SIG/firmware.keyblock" \
         "$SIG/firmware_data_key.vbprivk" "$SIG/kernel_subkey.vbpubk"; do
  [ -r "$f" ] || die "cannot read $f"
done

cp "$IN" "$OUT"
"$FUTILITY" gbb --set --rootkey="$PUB/root_key.vbpubk" --recoverykey="$PUB/recovery_key.vbpubk" \
  --flags=0 "$OUT" >/dev/null
"$FUTILITY" sign --signprivate "$SIG/firmware_data_key.vbprivk" --keyblock "$SIG/firmware.keyblock" \
  --kernelkey "$SIG/kernel_subkey.vbpubk" --version "$VERSION" --flags 0 "$OUT" >/dev/null

# Check the result the way the firmware will: the GBB holds these keys, and
# both slots verify against that root key and carry this kernel subkey.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$FUTILITY" gbb --get --flags --rootkey="$tmp/root" --recoverykey="$tmp/rec" "$OUT" > "$tmp/gbb"
grep -q 'flags: 0x00000000' "$tmp/gbb" || die "GBB flags are not 0"
[ "$(sha1_of "$tmp/root")" = "$(sha1_of "$PUB/root_key.vbpubk")" ] || die "GBB root key is not the one given"
[ "$(sha1_of "$tmp/rec")" = "$(sha1_of "$PUB/recovery_key.vbpubk")" ] || die "GBB recovery key is not the one given"
"$FUTILITY" show --publickey "$PUB/root_key.vbpubk" "$OUT" > "$tmp/show"
[ "$(grep -c 'Signature: *valid' "$tmp/show")" -ge 2 ] || { cat "$tmp/show"; die "RW slots do not verify against the root key"; }
subkey=$(sha1_of "$SIG/kernel_subkey.vbpubk")
[ "$(grep -c "$subkey" "$tmp/show")" -ge 2 ] || die "RW preambles do not carry the kernel subkey"
echo "rekeyed: root $(sha1_of "$PUB/root_key.vbpubk"), GBB flags 0, both RW slots verify"
sha256sum "$OUT"
