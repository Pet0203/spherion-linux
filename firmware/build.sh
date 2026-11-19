#!/usr/bin/env bash
# Build a complete 8 MiB firmware image for google,spherion from the sources
# pinned in manifest.yml plus the patches in firmware/patches/, following
# ChromeOS's own ebuilds (coreboot, libpayload, depthcharge, chromeos-ec,
# chromeos-bootimage), and sign both RW slots with the public vboot developer
# keys that ship in the vboot tree.
#
# The result is not for flashing as it is: everybody has those keys. rekey.sh
# turns it into an image that trusts your own keys, and prepare-flash.sh carries
# your machine's identity over into it. See firmware/README.md.
#
# Expects under $SRC (fetch-sources.sh creates all but the last two):
#   coreboot/ (+ 3rdparty/{arm-trusted-firmware,vboot,blobs}), depthcharge/, ec/,
#   coreboot/util/crossgcc/xgcc/   the aarch64 and riscv cross compilers
#   ui-assets/                     vbgfx.bin font.bin locale_en.bin, taken from
#                                  your own stock firmware image
#
# Usage: build.sh
#
# Environment:
#   SRC      where the source trees are (default ~/src)
#   OUT      build directory, wiped on every run (default $SRC/out/spherion)
#   FWID     appended to "Google_Spherion" to make the firmware ID that
#            crossystem reports (default .13885.143.0-custom)
#   SKIP_EC  set to build without the EC, leaving ecrw out of the image
#   JOBS, SOURCE_DATE_EPOCH
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-$HOME/src}
OUT=${OUT:-$SRC/out/spherion}
JOBS=${JOBS:-$(nproc)}
CB=$SRC/coreboot
XGCC=$CB/util/crossgcc/xgcc/bin
KEYS=$CB/3rdparty/vboot/tests/devkeys
# Appended to "Google_Spherion" to make the firmware ID crossystem reports.
# Say that this is not Google's build.
FWID=${FWID:-.13885.143.0-custom}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

for d in "$CB" "$CB/3rdparty/arm-trusted-firmware" "$CB/3rdparty/vboot" "$CB/3rdparty/blobs" \
         "$SRC/depthcharge" "$SRC/ec" "$SRC/ui-assets"; do
  [ -d "$d" ] || die "missing $d"
done
[ -x "$XGCC/aarch64-elf-gcc" ] || die "no aarch64 crossgcc in $XGCC"

# Patch queues. Everything added on top of the pinned sources lives in
# firmware/patches/, so a build is reproducible from the manifest plus those
# files and nothing else -- but only if the tree starts where the manifest says.
# A tree left patched by an earlier run is not that tree: the moment a patch
# file changes, its old version is still applied and the new one will not go
# on. So put each patched tree back on its pinned commit first.
#
# This discards local changes in coreboot, vboot and depthcharge.
pinned_commit() {   # pinned_commit KEY -- the commit manifest.yml pins for it
  awk -v k="  $1:" '
    $0 == k { in_k = 1; next }
    in_k && /^  [a-z_-]+:/ { exit }
    in_k && $1 == "commit:" { print $2; exit }
  ' "$REPO/firmware/manifest.yml"
}

reset_tree() {   # reset_tree TREE COMMIT NAME [noclean]
  local tree=$1 commit=$2 name=$3 mode=${4:-clean}
  [ -n "$commit" ] || die "manifest.yml pins no commit for $name"
  git -C "$tree" rev-parse --verify --quiet "$commit^{commit}" >/dev/null \
    || die "$tree is not at, and cannot reach, $name's pinned $commit"
  git -C "$tree" checkout -q -f "$commit"
  # Untracked files only: build output is gitignored and survives, so this
  # costs nothing but the patched sources. coreboot is asked not to, because
  # its tree carries untracked build-adjacent state (generated configs,
  # toolchain stamps) that is expensive to recreate and that no patch of ours
  # touches -- checkout -f is enough to undo what was applied.
  if [ "$mode" != noclean ]; then
    git -C "$tree" clean -qfd
  fi
  echo "    reset $name to ${commit:0:12}"
}

apply_queue() {   # apply_queue QUEUE_DIR TREE
  local queue=$1 tree=$2 p
  [ -d "$queue" ] || return 0
  for p in "$queue"/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$tree" apply --reverse --check "$p" 2>/dev/null; then
      echo "    already applied: $(basename "$p")"
      continue
    fi
    git -C "$tree" apply --whitespace=nowarn "$p" \
      || die "failed to apply $(basename "$p") to $tree"
    echo "    applied: $(basename "$p")"
  done
}
step "patch queues"
reset_tree "$CB" "$(pinned_commit coreboot)" coreboot noclean
reset_tree "$CB/3rdparty/vboot" "$(pinned_commit vboot)" vboot
reset_tree "$SRC/depthcharge" "$(pinned_commit depthcharge)" depthcharge
apply_queue "$REPO/firmware/patches/coreboot" "$CB"
apply_queue "$REPO/firmware/patches/vboot" "$CB/3rdparty/vboot"
apply_queue "$REPO/firmware/patches/depthcharge" "$SRC/depthcharge"
# Never inherit the caller's directory: find(1) fails ("cannot restore initial
# working directory") if it is not readable by the user the build runs as, for
# example when this is started through sudo from another user's directory.
cd "$SRC"
# SKIP_EC=1 builds and assembles everything except the EC (no ecrw in the
# image), e.g. while the RISC-V toolchain is still being built. Do not flash
# such an image.
SKIP_EC=${SKIP_EC:-}
[ -n "$SKIP_EC" ] || [ -x "$XGCC/riscv64-elf-gcc" ] || die "no riscv crossgcc in $XGCC"

# The pinned trees predate C23 (GCC 15+ default) and C++17, so host tools
# (cbfstool, futility, EC utilities) are compiled as gnu17 / gnu++14.
HOSTBIN=$HOME/.local/crossgcc-host-bin
mkdir -p "$HOSTBIN"
# -Wno-error comes after the caller's flags: coreboot's host tools build with
# -Werror, and GCC 16 warns about 2021 code (unterminated string initializers,
# format-overflow, discarded qualifiers, maybe-uninitialized). A plain
# -Wno-error does not undo a targeted -Werror=<warning>, hence the explicit ones.
printf '#!/bin/sh\nexec /usr/bin/gcc -std=gnu17 "$@" -Wno-error -Wno-error=maybe-uninitialized -Wno-error=discarded-qualifiers\n' > "$HOSTBIN/gcc"
printf '#!/bin/sh\nexec /usr/bin/g++ -std=gnu++14 "$@" -Wno-error -Wno-error=maybe-uninitialized\n' > "$HOSTBIN/g++"
chmod 0755 "$HOSTBIN/gcc" "$HOSTBIN/g++"
ln -sf gcc "$HOSTBIN/cc"; ln -sf g++ "$HOSTBIN/c++"
export PATH=$HOSTBIN:$PATH
unset CFLAGS CXXFLAGS LDFLAGS

# coreboot, libpayload and depthcharge stamp the build time into their images,
# so pin it; two builds of the same sources then produce the same bytes. The
# default is the pinned coreboot commit's own date.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git -C "$CB" log -1 --format=%ct 2>/dev/null || echo 1600000000)
fi
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" 2>/dev/null))"

rm -rf "$OUT"; mkdir -p "$OUT"

if [ -z "$SKIP_EC" ]; then
  step "EC RW (spherion, it8xxx2 RISC-V)"
  # Build the RW image only. "all" also builds host tools (ectool, cbi-util)
  # that do not compile under GCC 16, and the image is all CBFS needs.
  EC_RW=$SRC/ec/build/spherion/RW/ec.RW.flat
  make -C "$SRC/ec" BOARD=spherion clean >/dev/null
  make -C "$SRC/ec" BOARD=spherion CROSS_COMPILE_riscv="$XGCC/riscv64-elf-" -j"$JOBS" \
    "build/spherion/RW/ec.RW.flat"
  [ -s "$EC_RW" ] || die "EC build produced no $EC_RW"
  openssl dgst -sha256 -binary "$EC_RW" > "$OUT/ec.RW.hash"
fi

step "libpayload (config.asurada)"
(
  cd "$CB/payloads/libpayload"
  rm -rf build .xcompile
  cp "$REPO/firmware/configs/libpayload-asurada.config" .config
  # olddefconfig instead of piping yes into oldconfig: under pipefail the
  # yes process dies of SIGPIPE when make exits and fails the pipeline.
  make obj=build olddefconfig >/dev/null
  make obj=build -j"$JOBS"
  make obj=build DESTDIR="$OUT/firmware" install
)
[ -f "$OUT/firmware/libpayload/libpayload.config" ] || die "libpayload install missing"

step "coreboot (config.spherion + ChromeOS additions)"
CBCFG=$OUT/coreboot.config
{
  cat "$REPO/firmware/configs/coreboot-spherion.config"
  echo
  # The additions coreboot-9999.ebuild's create_config() makes, limited to the
  # ones present in the config embedded in the stock image.
  echo "CONFIG_EC_GOOGLE_CHROMEEC_FIRMWARE_NONE=y"
  echo "CONFIG_EC_GOOGLE_CHROMEEC_PD_FIRMWARE_NONE=y"
  echo "CONFIG_GBB_FLAG_DEV_SCREEN_SHORT_DELAY=y"
  echo "CONFIG_GBB_FLAG_FORCE_DEV_SWITCH_ON=y"
  echo "CONFIG_VBOOT_FWID_VERSION=\"$FWID\""
  # coreboot refuses to build unless it finds its own iasl, the x86 ACPI
  # compiler, whose 2020 tarball is no longer downloadable. ARM boards never
  # use it. This skips the toolchain version checks; the assertion below
  # confirms the pinned cross compiler was still the one used.
  echo "CONFIG_ANY_TOOLCHAIN=y"
} > "$CBCFG"
(
  cd "$CB"
  rm -rf .xcompile
  make DOTCONFIG="$CBCFG" obj="$OUT/coreboot" olddefconfig >/dev/null
  make DOTCONFIG="$CBCFG" obj="$OUT/coreboot" -j"$JOBS"
)
# Confirm the pinned cross compiler was used. coreboot records it in
# .xcompile, whose location varies with obj=, so search for it; if it is
# missing, warn rather than fail (coreboot's default search path is $XGCC).
XCOMPILE=$(find "$OUT/coreboot" "$CB" -maxdepth 2 -name ".xcompile" -print -quit 2>/dev/null || true)
if [ -n "$XCOMPILE" ]; then
  grep -q "aarch64-elf-gcc" "$XCOMPILE" || die "coreboot did not pick the pinned aarch64 toolchain ($XCOMPILE)"
  grep -q "$XGCC" "$XCOMPILE" || die "coreboot used a toolchain outside $XGCC ($XCOMPILE)"
  echo "toolchain: $(grep -m1 aarch64 "$XCOMPILE")"
else
  echo "warning: no .xcompile found; could not confirm the toolchain" >&2
fi
CBFSTOOL=$OUT/coreboot/cbfstool
FUTILITY=$(find "$OUT/coreboot" -type f -name futility -perm -u+x | head -1)
[ -x "$CBFSTOOL" ] || die "no cbfstool"
[ -x "$FUTILITY" ] || die "no futility"
"$CBFSTOOL" "$OUT/coreboot/coreboot.rom" expand -r FW_MAIN_A,FW_MAIN_B

step "depthcharge (board asurada)"
DC=(-C "$SRC/depthcharge" obj="$OUT/depthcharge" DOTCONFIG="$OUT/depthcharge/depthcharge.config"
    LIBPAYLOAD_DIR="$OUT/firmware/libpayload" VB_SOURCE="$CB/3rdparty/vboot" EC_HEADERS="$SRC/ec/include")
mkdir -p "$OUT/depthcharge"
# coreboot generates the FW_CONFIG decoder header from the devicetree, and
# depthcharge includes it from its obj directory (as the ChromeOS ebuilds do).
[ -s "$OUT/coreboot/static_fw_config.h" ] || die "coreboot produced no static_fw_config.h"
cp "$OUT/coreboot/static_fw_config.h" "$OUT/depthcharge/static_fw_config.h"
make "${DC[@]}" KBUILD_DEFCONFIG="$SRC/depthcharge/board/asurada/defconfig" defconfig
make "${DC[@]}" -j"$JOBS" depthcharge
DC_ELF=$OUT/depthcharge/depthcharge.elf
[ -s "$DC_ELF" ] || die "no $DC_ELF"

step "assemble (chromeos-bootimage)"
IMG=$OUT/image-spherion.dev.bin   # "dev": signed with the public developer keys
cp "$OUT/coreboot/coreboot.rom" "$IMG"
"$CBFSTOOL" "$IMG" add-payload -f "$DC_ELF" -n fallback/payload -c lzma
"$CBFSTOOL" "$IMG" add-payload -f "$DC_ELF" -n fallback/payload -c lzma -r FW_MAIN_A,FW_MAIN_B
if [ -z "$SKIP_EC" ]; then
  "$CBFSTOOL" "$IMG" add -r FW_MAIN_A,FW_MAIN_B -t raw -c lzma -f "$EC_RW" -n ecrw -p 0
  "$CBFSTOOL" "$IMG" add -r FW_MAIN_A,FW_MAIN_B -t raw -c none -f "$OUT/ec.RW.hash" -n ecrw.hash
fi
# Firmware-screen assets from the stock image, English only (the stock RO
# carries ~50 locales and is 98% full).
printf 'en,0\n' > "$OUT/locales"
for f in vbgfx.bin font.bin locale_en.bin; do
  "$CBFSTOOL" "$IMG" add -r COREBOOT -t raw -c lzma -f "$SRC/ui-assets/$f" -n "$f"
done
"$CBFSTOOL" "$IMG" add -r COREBOOT -t raw -c lzma -f "$OUT/locales" -n locales

step "sign RW slots with the vboot dev keys"
sign_region() {   # port of chromeos-bootimage sign_region()
  local slot=$1 body vblock size
  body=$(mktemp); vblock=$body.out
  "$CBFSTOOL" "$IMG" read -r "FW_MAIN_$slot" -f "$body"
  size=$("$CBFSTOOL" "$IMG" print -k -r "FW_MAIN_$slot" | tail -1 |
         sed -n 's/^(empty)[[:space:]]\(0x[0-9a-f]*\)\tnull\t.*$/\1/p')
  if [ -n "$size" ] && [ "$(printf '%d' "$size")" -gt 0 ]; then
    head -c "$(printf '%d' "$size")" "$body" > "$body.trim" && mv "$body.trim" "$body"
    "$CBFSTOOL" "$IMG" write --force -u -i 255 -r "FW_MAIN_$slot" -f "$body"
  fi
  "$FUTILITY" vbutil_firmware --vblock "$vblock" --keyblock "$KEYS/firmware.keyblock" \
    --signprivate "$KEYS/firmware_data_key.vbprivk" --version 1 --fv "$body" \
    --kernelkey "$KEYS/kernel_subkey.vbpubk" --flags 0
  "$CBFSTOOL" "$IMG" write -u -i 255 -r "VBLOCK_$slot" -f "$vblock"
  rm -f "$body" "$vblock"
}
sign_region A
sign_region B
"$FUTILITY" show "$IMG" | grep -E "Signature|Firmware version|Data key" || true

step "result"
sha256sum "$IMG"
echo "$IMG"
