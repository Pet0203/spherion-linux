#!/usr/bin/env bash
# Fetch the source trees manifest.yml pins, each at exactly its pinned commit,
# into the layout build.sh expects:
#
#   $SRC/coreboot
#   $SRC/coreboot/3rdparty/arm-trusted-firmware
#   $SRC/coreboot/3rdparty/vboot
#   $SRC/coreboot/3rdparty/blobs
#   $SRC/depthcharge
#   $SRC/ec
#
# Google's coreboot fork has no usable submodule setup on this branch, so the
# 3rdparty trees are cloned into place one by one. Each fetch is a shallow fetch
# of a single commit by its full hash.
#
# Usage: fetch-sources.sh            (SRC defaults to ~/src)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST=$REPO/firmware/manifest.yml
SRC=${SRC:-$HOME/src}

die() { echo "error: $*" >&2; exit 1; }

field() {   # field KEY NAME -- the value of "NAME:" under "  KEY:" in the manifest
  awk -v k="  $1:" -v n="$2:" '
    $0 == k { in_k = 1; next }
    in_k && /^  [a-z_-]+:/ { exit }
    in_k && $1 == n { print $2; exit }
  ' "$MANIFEST"
}

fetch() {   # fetch KEY DESTINATION
  local key=$1 dest=$2 url commit have
  url=$(field "$key" url)
  commit=$(field "$key" commit)
  [ -n "$url" ] && [ -n "$commit" ] || die "manifest.yml has no url/commit for $key"
  if [ -d "$dest/.git" ]; then
    have=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
    if [ "$have" = "$commit" ]; then
      echo "$key: already at ${commit:0:12}"
      return
    fi
  else
    mkdir -p "$dest"
    git -C "$dest" init -q
  fi
  echo "$key: fetching ${commit:0:12} from $url"
  git -C "$dest" fetch -q --depth 1 "$url" "$commit"
  git -C "$dest" checkout -q -f FETCH_HEAD
  [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || die "$dest is not at $commit"
}

fetch coreboot             "$SRC/coreboot"
fetch arm-trusted-firmware "$SRC/coreboot/3rdparty/arm-trusted-firmware"
fetch vboot                "$SRC/coreboot/3rdparty/vboot"
fetch blobs                "$SRC/coreboot/3rdparty/blobs"
fetch depthcharge          "$SRC/depthcharge"
fetch ec                   "$SRC/ec"

echo
echo "sources are in $SRC. Still needed before build.sh, see firmware/README.md:"
echo "  - the cross compilers under $SRC/coreboot/util/crossgcc/xgcc"
echo "  - $SRC/ui-assets, taken from your own stock firmware image"
