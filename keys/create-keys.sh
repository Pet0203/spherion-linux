#!/usr/bin/env bash
# Create a complete vboot key set of your own: the keys a Chromebook's firmware
# and kernel partitions are verified against.
#
# Run it once for the real set, on a machine that is offline, and decide before
# you start where the offline/ directory will live: whoever holds it can sign
# firmware your machine will accept. It is just as useful for throwaway sets to
# rehearse the whole procedure with first.
#
# Usage: create-keys.sh OUTDIR
# Needs openssl, futility and dumpRSAPublicKey (override with FUTILITY, DUMPRSA).
# Takes a minute or two on a fast machine, ten on a slow one: four of the six
# keys are RSA-8192.
#
# Sizes: RSA-8192 for the keys that live for years and are verified once per
# boot (root, recovery, kernel subkey, recovery kernel data key); RSA-4096 for
# the firmware and kernel data keys that sign every release.
#
# Every version is 1. In normal mode vboot rolls the TPM's minimum versions
# forward to whatever it boots; anything above 1 would make Google's stock
# firmware, which is version 1, impossible to restore.
#
# Output:
#   OUTDIR/public/   public keys and keyblocks; nothing secret
#   OUTDIR/signing/  what signing a firmware or a kernel needs: the data keys
#                    and the keyblocks
#   OUTDIR/offline/  root, recovery and kernel subkey private keys. Needed again
#                    only to issue new data keys; keep them off any networked
#                    machine
set -euo pipefail
umask 077

OUT=${1:?usage: create-keys.sh OUTDIR}
FUTILITY=${FUTILITY:-futility}
DUMPRSA=${DUMPRSA:-dumpRSAPublicKey}
RSA4096_SHA256=7
RSA8192_SHA512=11

die() { echo "error: $*" >&2; exit 1; }
[ ! -e "$OUT" ] || die "$OUT already exists; refusing to overwrite a key set"
for t in openssl "$FUTILITY" "$DUMPRSA"; do command -v "$t" >/dev/null || die "$t not found"; done
mkdir -p "$OUT"/{public,signing,offline,work}
W=$OUT/work
trap 'find "$W" -type f -exec shred -u {} + 2>/dev/null; rmdir "$W" 2>/dev/null || true' EXIT

make_pair() {   # make_pair NAME ALGORITHM VERSION PRIVATE_DIR
  local name=$1 algo=$2 version=$3 privdir=$4 bits
  case "$algo" in
    "$RSA4096_SHA256") bits=4096 ;;
    "$RSA8192_SHA512") bits=8192 ;;
    *) die "unknown algorithm $algo" ;;
  esac
  echo "generating $name (RSA-$bits)"
  openssl genrsa -out "$W/$name.pem" "$bits" 2>/dev/null
  openssl req -batch -new -x509 -key "$W/$name.pem" -out "$W/$name.crt" -subj "/CN=vboot $name/"
  "$DUMPRSA" -cert "$W/$name.crt" > "$W/$name.keyb"
  "$FUTILITY" vbutil_key --pack "$OUT/public/$name.vbpubk" --key "$W/$name.keyb" \
    --version "$version" --algorithm "$algo" >/dev/null
  # vbutil_key first tries the PEM as a packed public key and complains about its
  # size before reading it as a private key; that message means nothing.
  "$FUTILITY" vbutil_key --pack "$OUT/$privdir/$name.vbprivk" --key "$W/$name.pem" \
    --algorithm "$algo" >/dev/null 2>&1 || die "could not pack $name.vbprivk"
}

make_keyblock() {   # make_keyblock NAME MODE DATA_KEY SIGNING_KEY SIGNING_KEY_DIR
  local name=$1 mode=$2 data=$3 signer=$4 signdir=$5
  "$FUTILITY" vbutil_keyblock --pack "$OUT/public/$name.keyblock" --flags "$mode" \
    --datapubkey "$OUT/public/$data.vbpubk" --signprivate "$OUT/$signdir/$signer.vbprivk" >/dev/null
  # Check it against the public half of its signer before going on.
  "$FUTILITY" vbutil_keyblock --unpack "$OUT/public/$name.keyblock" \
    --signpubkey "$OUT/public/$signer.vbpubk" >/dev/null || die "$name keyblock does not verify"
}

make_pair root_key                 "$RSA8192_SHA512" 1 offline
make_pair recovery_key             "$RSA8192_SHA512" 1 offline
make_pair kernel_subkey            "$RSA8192_SHA512" 1 offline
make_pair firmware_data_key        "$RSA4096_SHA256" 1 signing
make_pair kernel_data_key          "$RSA4096_SHA256" 1 signing
make_pair recovery_kernel_data_key "$RSA8192_SHA512" 1 signing

# Keyblock modes: 7 = developer or normal mode, not recovery; 11 = recovery only.
make_keyblock firmware        7  firmware_data_key        root_key      offline
make_keyblock kernel          7  kernel_data_key          kernel_subkey offline
make_keyblock recovery_kernel 11 recovery_kernel_data_key recovery_key  offline

# Prove every signing key works before anything leaves this machine: sign a
# dummy firmware body and dummy kernels exactly as the build will, and verify
# them the way the firmware will.
head -c 65536 /dev/urandom > "$W/body"
"$FUTILITY" vbutil_firmware --vblock "$W/vblock" --keyblock "$OUT/public/firmware.keyblock" \
  --signprivate "$OUT/signing/firmware_data_key.vbprivk" --version 1 --fv "$W/body" \
  --kernelkey "$OUT/public/kernel_subkey.vbpubk" --flags 0 >/dev/null
"$FUTILITY" vbutil_firmware --verify "$W/vblock" --signpubkey "$OUT/public/root_key.vbpubk" \
  --fv "$W/body" >/dev/null || die "firmware data key does not verify against the root key"
head -c 512 /dev/zero > "$W/bootloader"
echo "console=tty1" > "$W/config"
for pair in "kernel kernel_data_key kernel_subkey" "recovery_kernel recovery_kernel_data_key recovery_key"; do
  set -- $pair
  "$FUTILITY" vbutil_kernel --pack "$W/$1.kpart" --keyblock "$OUT/public/$1.keyblock" \
    --signprivate "$OUT/signing/$2.vbprivk" --version 1 --vmlinuz "$W/body" \
    --bootloader "$W/bootloader" --config "$W/config" --arch aarch64 >/dev/null
  "$FUTILITY" vbutil_kernel --verify "$W/$1.kpart" --signpubkey "$OUT/public/$3.vbpubk" >/dev/null \
    || die "$2 does not verify against $3"
done
echo "every signing key verifies against its root"

cp "$OUT"/public/{firmware,kernel,recovery_kernel}.keyblock "$OUT"/public/kernel_subkey.vbpubk "$OUT/signing/"
printf '%s=1\n' firmware_key_version firmware_version kernel_key_version kernel_version > "$OUT/public/key.versions"
(cd "$OUT/public" && sha256sum -- * > SHA256SUMS)
(cd "$OUT/signing" && sha256sum -- * > SHA256SUMS)
(cd "$OUT/offline" && sha256sum -- * > SHA256SUMS)

echo
echo "key set in $OUT"
for k in root_key recovery_key kernel_subkey firmware_data_key kernel_data_key recovery_kernel_data_key; do
  printf '  %-26s %s\n' "$k" "$("$FUTILITY" show "$OUT/public/$k.vbpubk" | sed -n 's/.*Key sha1sum: *//p')"
done
