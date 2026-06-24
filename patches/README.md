# GT-BE98 kernel — official source + reviewable delta

The GT-BE98 kernel is **official kernel.org Linux 4.19.294** plus a reviewable
delta carried here. `scripts/fetch-mainline.sh` reconstructs the exact SDK kernel
source from the pristine tarball + these files (validated: **0 source-file
differences**; only kbuild-generated `include/config` / `include/generated`
differ, which `make` recreates).

Pristine base: `linux-4.19.294.tar.xz`
sha256 `ccadbde939a788934436125a1ecd4464175b68ebe6c18072fbc90c8596eea00f`
(verified by the script).

## The delta, split for review (OpenWrt/Yocto style)

| Piece | What | Size |
|---|---|---|
| `bcm-kf-mods.patch` | Edits to **upstream** files only — the auditable `CONFIG_BCM_KF_*` footprint. | **362 files, +11,832 / −186** |
| `../overlay/` | Wholly-**new** vendor source files added on top of mainline (browse them directly): `arch/arm/mach-bcm963xx`, `Kconfig.bcmconfig`, backported `net/wireguard` + `net/mptcp`, the bcm IIO tree, etc. | **722 files, ~10M** |
| `deletions.list` | Upstream files the vendor **removes** (other arches / docs). | 234 |

## No binary blobs in the kernel

Verified: **0 binary files differ** from mainline, and every binary in the SDK
kernel tree is build output (`vmlinux`, `*.o`, `scripts/dtc`, `initramfs_data.cpio`,
`config_data.gz`, …) that `make` regenerates — not shipped blobs. The proprietary
WiFi blobs (`wl`/`dhd`) live in **`bcmdrivers/`, outside the kernel tree**, and are
not needed to reconstruct or compile the kernel image. (A future `bcmdrivers`
layer is where a real `blobs/` dir would belong.)

## Reconstruct

```bash
scripts/fetch-mainline.sh            # -> build/linux-4.19.294 (official + delta)
VERIFY=1 scripts/fetch-mainline.sh   # also diff the result against the SDK $KD
```

## Regenerating this delta (when the SDK kernel changes)

Diff the SDK tree against a pristine kernel.org tree of the same version,
excluding build artifacts + vendor `config_*` staging files:
- `bcm-kf-mods.patch` = `diff -ru` of files present in **both** (skip `Only in` / `diff` lines).
- `overlay/` = files **only in** the SDK tree (minus build artifacts), copied with `rsync -aR`.
- `deletions.list` = files **only in** pristine.

Build-artifact excludes used: `*.o *.ko *.cmd .*.cmd *.a built-in* modules.* Module.symvers
System.map vmlinux* *.dtb Image* include/config include/generated arch/*/include/generated
.tmp* *.tab.c *.lex.c conf mconf vdso.so* config_data.gz *.d`, and the host-tool binaries
(`dtc kallsyms fixdep modpost …`). Vendor scratch excluded (not kernel source):
`config_base.6a.* config_current config_gt-be98 rdp_*flags.txt`.
