#!/usr/bin/env bash
# fetch-mainline.sh — reconstruct the GT-BE98 kernel SOURCE from the OFFICIAL
# kernel.org Linux 4.19.294 release + this repo's reviewable delta.
#
# The delta is split (OpenWrt/Yocto style) into three reviewable pieces:
#   patches/bcm-kf-mods.patch  edits to UPSTREAM files only (362 files,
#                              +11832/-186 lines) — the auditable BCM_KF footprint
#   overlay/                   wholly-new vendor source files (722 files, ~10M):
#                              arch/arm/mach-bcm963xx, Kconfig.bcmconfig, backported
#                              net/wireguard + net/mptcp, the bcm IIO tree, etc.
#   patches/deletions.list     upstream files the vendor removes (234)
#
# There are NO binary blobs in the kernel tree — verified: 0 binary files differ
# from mainline; every binary in the SDK tree is build output. The proprietary
# wl/dhd blobs live in bcmdrivers/, OUTSIDE the kernel, and are not needed to
# reconstruct or compile the kernel image.
#
# Reconstruct(pristine 4.19.294, +mods, +overlay, -deletions) == the SDK kernel
# tree for every SOURCE file (validated: 0 source differences; only kbuild-
# generated include/config + include/generated differ, recreated by `make`).
#
# Usage:
#   scripts/fetch-mainline.sh [OUTDIR]    # default <repo>/build/linux-4.19.294
#   VERIFY=1 scripts/fetch-mainline.sh    # then diff reconstructed source vs $KD
#   scripts/fetch-mainline.sh --into-sdk  # rsync reconstructed source INTO $KD (asks)
#
# Env: KVER (4.19.294), MIRROR (cdn.kernel.org), KD (for VERIFY/--into-sdk).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

KVER="${KVER:-4.19.294}"
MIRROR="${MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v4.x}"
TARBALL="linux-$KVER.tar.xz"
SHA256_4_19_294="ccadbde939a788934436125a1ecd4464175b68ebe6c18072fbc90c8596eea00f"
MODS="$REPO/patches/bcm-kf-mods.patch"
DELS="$REPO/patches/deletions.list"
OVL="$REPO/overlay"

die()  { echo "fetch-mainline: ERROR: $*" >&2; exit 1; }
info() { echo "fetch-mainline: $*"; }

INTO_SDK=0; OUTDIR=""
for a in "$@"; do
    case "$a" in
        --into-sdk) INTO_SDK=1 ;;
        -*) die "unknown option: $a" ;;
        *)  OUTDIR="$a" ;;
    esac
done
OUTDIR="${OUTDIR:-$REPO/build/linux-$KVER}"
DL="$REPO/build"; mkdir -p "$DL"

[[ -f "$MODS" ]] || die "missing $MODS"
[[ -d "$OVL"  ]] || die "missing overlay dir $OVL"
command -v patch >/dev/null || die "need patch"
command -v rsync >/dev/null || die "need rsync"

# 1. download (cached)
if [[ ! -f "$DL/$TARBALL" ]]; then
    info "downloading $MIRROR/$TARBALL"
    curl -fL --retry 3 -o "$DL/$TARBALL" "$MIRROR/$TARBALL"
fi
# 2. verify integrity
if [[ "$KVER" == "4.19.294" ]]; then
    have="$(sha256sum "$DL/$TARBALL" | awk '{print $1}')"
    [[ "$have" == "$SHA256_4_19_294" ]] || die "sha256 mismatch: $have != $SHA256_4_19_294"
    info "sha256 OK"
else
    info "WARN: no pinned sha256 for $KVER — skipping verify"
fi
# 3. extract pristine
[[ -e "$OUTDIR" ]] && die "OUTDIR exists: $OUTDIR (remove it or pass another path)"
info "extracting pristine into $OUTDIR"
mkdir -p "$(dirname "$OUTDIR")"
tar -C "$(dirname "$OUTDIR")" -xf "$DL/$TARBALL"
[[ -d "$(dirname "$OUTDIR")/linux-$KVER" && "$(dirname "$OUTDIR")/linux-$KVER" != "$OUTDIR" ]] \
    && mv "$(dirname "$OUTDIR")/linux-$KVER" "$OUTDIR"

# 4. apply mods patch (edits to upstream files)
info "applying patches/bcm-kf-mods.patch ($(grep -c '^+++ ' "$MODS") files)"
( cd "$OUTDIR" && patch -p1 --forward --batch -s < "$MODS" ) || die "mods patch failed"
# 5. overlay the added vendor source files
info "overlaying $(find "$OVL" -type f | wc -l) added vendor source files"
rsync -a "$OVL"/ "$OUTDIR"/
# 6. apply deletions (upstream files the vendor removed)
if [[ -f "$DELS" ]]; then
    info "removing $(grep -c . "$DELS") upstream files the vendor drops"
    ( cd "$OUTDIR" && while read -r p; do [[ -n "$p" ]] && rm -rf "./$p"; done < "$DELS" )
fi
info "reconstructed GT-BE98 kernel source at: $OUTDIR"
info "  ( = official linux-$KVER + patches/bcm-kf-mods.patch + overlay/ - deletions.list )"

# Excludes shared by VERIFY: build outputs + intentionally-excluded vendor scratch.
EXC=(--exclude=.git --exclude='.config*' --exclude='*.o' --exclude='*.cmd' --exclude='.*.cmd'
     --exclude='*.ko' --exclude='*.mod*' --exclude=include/config --exclude=include/generated
     --exclude='arch/*/include/generated' --exclude='System.map' --exclude='vmlinux*'
     --exclude=Module.symvers --exclude='*.order' --exclude='modules.builtin*' --exclude='built-in*'
     --exclude='*.a' --exclude='config_*' --exclude='*.dtb' --exclude='Image*' --exclude='gtbe98_defconfig'
     --exclude='zz_*' --exclude='.tmp*' --exclude='*.tab.c' --exclude='*.tab.h' --exclude='*.lex.c'
     --exclude=conf --exclude=mconf --exclude=nconf --exclude='rdp_*flags.txt' --exclude='config_data.gz'
     --exclude='.version' --exclude='.pre_kernelbuild' --exclude='.untar_complete' --exclude='*.d'
     # generated source + host-tool binaries + intentionally-dropped non-source
     --exclude='*.s' --exclude='*.asn1.c' --exclude='*.asn1.h' --exclude='*-core.S' --exclude='vdso.lds'
     --exclude='vdso.so*' --exclude='defconfig' --exclude='defconfig.prekprobe' --exclude='.gitignore'
     --exclude='x509_certificate_list' --exclude='gen_crc32table' --exclude='asn1_compiler'
     --exclude='fixdep' --exclude='bin2c' --exclude='dtc' --exclude='extract-cert' --exclude='kallsyms'
     --exclude='recordmcount' --exclude='sortextable' --exclude='unifdef' --exclude='modpost'
     --exclude='mk_elfconfig' --exclude='.missing-syscalls.d')

if [[ "${VERIFY:-0}" == 1 ]]; then
    # shellcheck source=scripts/kernel-env.sh
    source "$HERE/kernel-env.sh"
    [[ -d "$KD" ]] || die "VERIFY set but \$KD not found: $KD"
    info "diffing reconstructed source vs \$KD (source only) ..."
    # also drop dir-only residuals whose basename is a generated dir (config|generated)
    flt() { grep -viE 'include/config|/generated|: (generated|config)$'; }
    n="$(diff -rq "${EXC[@]}" "$OUTDIR" "$KD" 2>/dev/null | flt | wc -l)"
    if [[ "$n" -eq 0 ]]; then
        info "VERIFY OK: reconstructed source == \$KD (0 source differences)"
    else
        info "VERIFY: $n residual source differences:"
        diff -rq "${EXC[@]}" "$OUTDIR" "$KD" 2>/dev/null | flt | head
    fi
fi

if [[ "$INTO_SDK" == 1 ]]; then
    # shellcheck source=scripts/kernel-env.sh
    source "$HERE/kernel-env.sh"
    [[ -d "$KD" ]] || die "--into-sdk but \$KD not found: $KD"
    echo "About to rsync reconstructed SOURCE into the SDK kernel tree: $KD"
    echo "(preserves your .config, build outputs, and vendor config_* staging files)"
    read -r -p "Type YES to proceed: " ans; [[ "$ans" == YES ]] || die "aborted"
    rsync -a --exclude='.config*' --exclude=include/config --exclude=include/generated \
          --exclude='*.o' --exclude='*.ko' --exclude='*.cmd' --exclude=System.map \
          --exclude='vmlinux*' --exclude='built-in*' --exclude='config_*' "$OUTDIR"/ "$KD"/
    info "rsynced into $KD — now run configure-kernel.sh then build-kernel.sh"
fi
