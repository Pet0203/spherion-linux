# Firmware

Builds a complete 8 MiB firmware image for `google,spherion` from Google's own
sources at pinned commits, with five patches on top, and signs it with keys you
create.

What the result contains: coreboot, Arm Trusted Firmware (BL31), depthcharge and
the EC's RW image, all compiled here; the MediaTek blobs from Google's public
blobs repository, unchanged; and the firmware-screen bitmaps from your own
machine's stock image.

## The patches

Sources are pinned in [`manifest.yml`](manifest.yml) to the commits Google
built `Google_Spherion.13885.143.0` from.

| Tree | Patch | Why |
|---|---|---|
| coreboot | `mb/google/asurada: always bring the display up` | A normal-mode boot has no display, and the PIN prompt needs one |
| vboot | `tlcl: add TPM 2.0 policy sessions and a policy-authorised NV read` | The TPM commands the unlock needs, which vboot's small TPM library lacks |
| depthcharge | `vboot: add a firmware disk unlock` | The PIN screen, the TPM exchange, the handover to the kernel |
| depthcharge | `vboot: run the disk unlock when the kernel command line asks for it` | Wires it in |
| depthcharge | `input: mkbp: add a Swedish layout and select it on asurada` | **Only for Swedish/Finnish keyboards.** Delete this patch otherwise |

Without the patches, `build.sh` rebuilds the stock firmware, apart from the
serial console and the reduced set of locales. That is worth doing first: you
get an image to compare against your backup before changing anything. When this
was done, the five MediaTek blobs and the DRAM initialisation blob in the result
were byte-identical to the stock image's, and two builds with the same
`SOURCE_DATE_EPOCH` were byte-identical to each other.

If you only want your own keys and not the disk unlock, remove everything in
`patches/` and keep the rest of the procedure.

The configuration differs from Google's in one line: the serial console is
enabled (see [`configs/coreboot-spherion.config`](configs/coreboot-spherion.config)).

## Building

This was run on Arch Linux x86_64 in September 2026, with GCC 16 as the host
compiler. The sources are from 2021, and most of what follows exists to bridge
that gap.

### 1. Host packages

`base-devel git python python-setuptools python-kconfiglib acpica dtc uboot-tools
openssl lz4 xz zstd bc cpio perl wget curl`

- `python-kconfiglib` is for depthcharge's Kconfig.
- `acpica` provides `iasl`. coreboot's toolchain check insists on finding it
  even for ARM boards, which never compile ACPI.

### 2. Sources

```
firmware/fetch-sources.sh        # into ~/src, or set SRC
```

### 3. Cross compilers

coreboot's own, at the versions this branch pins (GCC 8.3), for aarch64 and for
the EC's RISC-V core:

```
cd ~/src/coreboot/util/crossgcc
./buildgcc -p aarch64-elf -j"$(nproc)"
./buildgcc -p riscv-elf -j"$(nproc)"
```

Two obstacles on a current distribution:

- `make crossgcc-aarch64` also builds `iasl` from a 2020 tarball that can no
  longer be downloaded. Calling `buildgcc -p` directly, as above, avoids it.
- GMP 6.2.0's configure fails under a host compiler that defaults to C23. Put a
  wrapper first in `PATH` that runs `gcc -std=gnu17` (and `g++ -std=gnu++14`)
  while the toolchain builds. `build.sh` sets up the same wrappers for its own
  host tools.

The compilers end up in `~/src/coreboot/util/crossgcc/xgcc/bin`, where
`build.sh` looks for them, and it checks afterwards that coreboot really used
them.

### 4. Firmware-screen assets

depthcharge draws its screens, the PIN prompt included, from three files in the
read-only CBFS: `vbgfx.bin`, `font.bin` and `locale_en.bin`. They are not built
from source here. Extract them from your own stock image into `~/src/ui-assets/`
with `cbfstool` (`make -C ~/src/coreboot/util/cbfstool` builds it):

```
cbfstool stock.bin extract -n vbgfx.bin     -f ~/src/ui-assets/vbgfx.bin
cbfstool stock.bin extract -n font.bin      -f ~/src/ui-assets/font.bin
cbfstool stock.bin extract -n locale_en.bin -f ~/src/ui-assets/locale_en.bin
```

`build.sh` compresses them again itself, so they must be the decompressed
files, which is what `extract` writes unless given `-U`. Only English is
put back: the stock image carries some fifty locales and its read-only section
is 98% full.

### 5. Build

```
FWID=.13885.143.0-mybuild firmware/build.sh
```

The result is `~/src/out/spherion/image-spherion.dev.bin`, with both RW slots
signed by the public vboot developer keys. `build.sh` resets the coreboot, vboot
and depthcharge trees to their pinned commits on every run before applying the
patches, so do not keep work in progress in them.

coreboot has to build before depthcharge: it generates `static_fw_config.h`,
which depthcharge includes.

### 6. Your keys

```
keys/create-keys.sh /somewhere/safe/keys
firmware/rekey.sh image-spherion.dev.bin image-spherion.bin \
    /somewhere/safe/keys/public /somewhere/safe/keys/signing
```

`create-keys.sh` writes three directories. `offline/` holds the root, recovery
and kernel-subkey private keys, which are needed again only to issue new signing
keys; `signing/` holds what signing a firmware or a kernel needs; `public/` is
not secret. Decide where `offline/` lives before you create it.

Every key and firmware version is 1, deliberately. In normal mode vboot rolls
the TPM's minimum versions forward to what it boots, and anything above 1 would
make the stock firmware (version 1) impossible to restore.

`rekey.sh` puts your root and recovery keys into the GBB with GBB flags 0,
re-signs both RW slots, and checks the result the way the firmware will.

Then continue with [`FLASHING.md`](FLASHING.md).

## What is still Google's

- **The EC's read-only image.** Only the EC's RW half is built here; it reaches
  the EC through software sync at boot. On this board the EC's RO accepts any RW
  image whose hash the AP firmware vouches for.
- **The Cr50's firmware**, which nothing here touches.
- **The MediaTek blobs** (DRAM calibration, SPM, MCUPM, SSPM, DPM), which have
  no public source.
