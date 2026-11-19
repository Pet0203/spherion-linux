#!/usr/bin/env bash
# Make the image to write for a full flash: the re-keyed image from rekey.sh,
# carrying over what belongs to one particular machine from a fresh read of its
# flash.
#
# Carried over, as futility update does on a full update: the vital product
# data (RO_VPD, RW_VPD: serial number, region), vboot's NVRAM (RW_NVRAM), the
# event log (RW_ELOG), and the HWID in the GBB. Everything else comes from the
# new image. Refuses if the two flash layouts differ in any way.
#
# Not needed when only the RW sections are written; see FLASHING.md.
#
# Usage: prepare-flash.sh CURRENT.bin NEW.bin OUT.bin
set -euo pipefail

CUR=${1:?usage: prepare-flash.sh CURRENT.bin NEW.bin OUT.bin}
NEW=${2:?}
OUT=${3:?}
FUTILITY=${FUTILITY:-futility}
SIZE=$((8 * 1024 * 1024))
PRESERVE=(RO_VPD RW_VPD RW_NVRAM RW_ELOG)

die() { echo "error: $*" >&2; exit 1; }
for f in "$CUR" "$NEW"; do
  [ "$(stat -c%s "$f")" -eq "$SIZE" ] || die "$f is not an 8 MiB flash image"
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$FUTILITY" dump_fmap -p "$CUR" > "$tmp/cur.fmap" || die "no FMAP in $CUR"
"$FUTILITY" dump_fmap -p "$NEW" > "$tmp/new.fmap" || die "no FMAP in $NEW"
cmp -s "$tmp/cur.fmap" "$tmp/new.fmap" || { diff "$tmp/cur.fmap" "$tmp/new.fmap" >&2; die "the flash layouts differ"; }

cp "$NEW" "$OUT"
for region in "${PRESERVE[@]}"; do
  read -r off len < <(awk -v r="$region" '$1 == r { print $2, $3 }' "$tmp/cur.fmap") || true
  [ -n "${off:-}" ] || die "no $region in the layout"
  dd if="$CUR" of="$OUT" bs=1 skip="$off" seek="$off" count="$len" conv=notrunc status=none
  echo "kept $region ($len bytes at $off) from $(basename "$CUR")"
  off=
done
hwid=$("$FUTILITY" gbb --get --hwid "$CUR" | sed -n 's/^hardware_id: //p')
[ -n "$hwid" ] || die "no HWID in $CUR"
# GBB flags 0: none of the developer shortcuts. The GBB is not signed, so this
# does not disturb the RW signatures.
"$FUTILITY" gbb --set --hwid="$hwid" --flags=0 "$OUT" >/dev/null
echo "kept HWID $hwid, GBB flags set to 0"

# What will change on the chip, by region.
echo
echo "regions that will change:"
while read -r name off len; do
  if ! cmp -s <(tail -c +$((off + 1)) "$CUR" | head -c "$len") <(tail -c +$((off + 1)) "$OUT" | head -c "$len"); then
    echo "  $name"
  fi
done < "$tmp/cur.fmap"

# The result has to verify on its own: flags 0, both RW slots against the root
# key now in its GBB.
"$FUTILITY" gbb --get --flags --hwid "$OUT" | sed 's/^/  /'
"$FUTILITY" gbb --get --flags "$OUT" | grep -q 'flags: 0x00000000' || die "GBB flags are not 0"
"$FUTILITY" show "$OUT" > "$tmp/show"
[ "$(grep -c 'Signature: *valid' "$tmp/show")" -ge 2 ] || die "the RW slots do not verify against the GBB root key"
echo "both RW slots verify against the root key in the image"
sha256sum "$OUT"
