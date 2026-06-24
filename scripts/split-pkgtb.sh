#!/usr/bin/env bash
# split-pkgtb.sh — split a merlin .pkgtb FIT container into its two flashable
# sub-images using dumpimage (u-boot-tools).
#
#   sub-image [0] = bootfs FIT  (ATF/BL31 + 2nd-stage u-boot + kernel + DTB), ~13MB
#   sub-image [1] = rootfs      (squashfs), ~62MB
#
# For a KERNEL-ONLY change you only need the bootfs (sub-image 0); flash that
# alone (see flash-slot1.sh). Extract the rootfs too only if it changed.
#
# Runs on dev-build (where the .pkgtb and dumpimage live).
#
# Usage:
#   scripts/split-pkgtb.sh <pkgtb> [outdir]
#   scripts/split-pkgtb.sh                      # auto-find the GT-BE98 pkgtb
#
# Env:
#   FW       default ~/be98/gt-be98-firmware
#   SDKDIR   default $FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
#   TARGET   default 96813GW
#   DUMPIMAGE default dumpimage
set -euo pipefail

FW="${FW:-$HOME/be98/gt-be98-firmware}"
SDKDIR="${SDKDIR:-$FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"
TARGET="${TARGET:-96813GW}"
DUMPIMAGE="${DUMPIMAGE:-dumpimage}"

die() { echo "split-pkgtb: ERROR: $*" >&2; exit 1; }
info(){ echo "split-pkgtb: $*"; }

command -v "$DUMPIMAGE" >/dev/null 2>&1 || die "$DUMPIMAGE not found (apt install u-boot-tools)"

PKGTB="${1:-}"
if [[ -z "$PKGTB" ]]; then
    # auto-find
    cands=( "$SDKDIR/targets/$TARGET"/GT-BE98_*_nand_squashfs.pkgtb )
    [[ -f "${cands[0]}" ]] || die "no .pkgtb under $SDKDIR/targets/$TARGET — pass one explicitly"
    [[ ${#cands[@]} -eq 1 ]] || { info "multiple pkgtb found, picking newest:"; PKGTB=$(ls -t "${cands[@]}" | head -1); }
    PKGTB="${PKGTB:-${cands[0]}}"
fi
[[ -f "$PKGTB" ]] || die "pkgtb not found: $PKGTB"

OUTDIR="${2:-$(dirname "$PKGTB")}"
mkdir -p "$OUTDIR"

info "source: $PKGTB"
info "outdir: $OUTDIR"

BOOTFS="$OUTDIR/bootfs.itb"
ROOTFS="$OUTDIR/rootfs.img"

info "extracting bootfs (sub-image 0) -> $BOOTFS"
"$DUMPIMAGE" -T flat_dt -p 0 -o "$BOOTFS" "$PKGTB"

info "extracting rootfs (sub-image 1) -> $ROOTFS"
"$DUMPIMAGE" -T flat_dt -p 1 -o "$ROOTFS" "$PKGTB" || \
    info "WARN rootfs extract failed (fine if you only need the bootfs)"

echo
ls -lh "$BOOTFS" "$ROOTFS" 2>/dev/null || ls -lh "$BOOTFS"
echo
info "bootfs.itb  -> slot1 bootfs volume (static)   [kernel-only change: flash THIS only]"
info "rootfs.img  -> slot1 rootfs volume (dynamic)"
info "next: scripts/flash-slot1.sh $BOOTFS   (transfers + flashes slot1, never slot2)"
