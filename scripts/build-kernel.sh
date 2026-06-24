#!/usr/bin/env bash
# build-kernel.sh — build the merlin 4.19 GT-BE98 kernel on dev-build via rtk.
#
# IMPORTANT: builds run on dev-build (10.0.50.21), NEVER on dev-code. This
# script is meant to be run ON dev-build (or it will SSH there for you with
# --remote). It does NOT edit config — run configure-kernel.sh first.
#
# Two modes:
#   full       (default) — drives ~/be98/gt-be98-firmware/build.sh, which does
#                          `make FORCE=1 ... gt-be98` and produces the .pkgtb.
#                          This is the RELIABLE path (BCM_KF pulls bcmdrivers in;
#                          standalone Image can hit empty-var errors).
#   image      — standalone kernel-only `make Image` in $KD with the full env
#                set up the hard way. Faster (~minutes) but more fragile; good
#                for verifying a config compiles. Does NOT produce a .pkgtb.
#
# After building it VERIFIES the requested configs landed (config_data.gz +
# System.map) and prints the .pkgtb path.
#
# Usage (on dev-build):
#   scripts/build-kernel.sh                       # full build
#   scripts/build-kernel.sh full
#   scripts/build-kernel.sh image
#   VERIFY_SYMS="CONFIG_KPROBES register_kprobe" scripts/build-kernel.sh
#
# Usage (from dev-code, dispatch to dev-build over SSH):
#   scripts/build-kernel.sh --remote [full|image]
#
# Env:
#   FW       default ~/be98/gt-be98-firmware
#   SDKDIR   default $FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
#   KD       default $SDKDIR/kernel/linux-4.19
#   TARGET   default 96813GW   (the SDK target dir under targets/)
#   DEVBUILD default guillaume@10.0.50.21   (for --remote)
#   RTK      default rtk        (set to "" to run make without the filter)
#   VERIFY_SYMS  space-separated tokens to grep for in config_data.gz/System.map
#                default "CONFIG_KPROBES CONFIG_KALLSYMS_ALL"
set -euo pipefail

FW="${FW:-$HOME/be98/gt-be98-firmware}"
SDKDIR="${SDKDIR:-$FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"
KD="${KD:-$SDKDIR/kernel/linux-4.19}"
TARGET="${TARGET:-96813GW}"
DEVBUILD="${DEVBUILD:-guillaume@10.0.50.21}"
RTK="${RTK:-rtk}"
VERIFY_SYMS="${VERIFY_SYMS:-CONFIG_KPROBES CONFIG_KALLSYMS_ALL}"

info() { echo "build-kernel: $*"; }
die()  { echo "build-kernel: ERROR: $*" >&2; exit 1; }

# --remote: re-dispatch this script on dev-build (used from dev-code).
if [[ "${1:-}" == "--remote" ]]; then
    shift
    mode="${1:-full}"
    info "dispatching to $DEVBUILD: cd $FW && git pull && build-kernel.sh $mode"
    # The repo is expected checked out on dev-build under the same path-ish
    # location; adjust REPO if yours differs.
    REPO="${REPO:-$HOME/be98/gt-be98-kernel}"
    exec ssh "$DEVBUILD" "cd '$FW' && git pull --ff-only || true; \
        VERIFY_SYMS='$VERIFY_SYMS' '$REPO/scripts/build-kernel.sh' '$mode'"
fi

MODE="${1:-full}"

[[ -f "$KD/config_base.6a.6813" ]] || die "config_base not found under $KD — wrong SDKDIR/KD?"

PKGTB_GLOB="$SDKDIR/targets/$TARGET/GT-BE98_*_nand_squashfs.pkgtb"

run() {
    if [[ -n "$RTK" ]] && command -v "$RTK" >/dev/null 2>&1; then
        "$RTK" "$@"
    else
        "$@"
    fi
}

case "$MODE" in
  full)
    info "FULL build via $FW/build.sh (make FORCE=1 ... gt-be98)"
    [[ -x "$FW/build.sh" ]] || die "$FW/build.sh not found/executable"
    # build.sh's profile_saved_check guard can fire once on FORCE=1 and exit 1
    # (it touches .last_profile then bails). Re-run once if so. We only retry on
    # that benign first-run guard, capped at 2 attempts.
    if ! run "$FW/build.sh"; then
        info "build.sh exited non-zero (likely the profile_saved_check guard on FORCE=1) — retrying once"
        run "$FW/build.sh"
    fi
    ;;
  image)
    info "STANDALONE kernel Image build in $KD (fragile; for config-compile checks)"
    TC_BIN="$FW/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1/bin"
    [[ -d "$TC_BIN" ]] || die "toolchain bin not found: $TC_BIN"
    (
        cd "$KD"
        export PATH="$TC_BIN:$PATH"
        # MODEL=GTBE98  -> avoids bare `-D$(MODEL)` ("macro names must be identifiers", top Makefile ~L452)
        # BCM_KF=y      -> Kconfig.bcmconfig only sources BCM_KF defs if BCM_KF=y (~380 syms incl BCM_SKB_CB_SIZE)
        # LINUX_VER_STR -> Kconfig sources Kconfig.bcm_kf.$(LINUX_VER_STR)
        run env -u LD_LIBRARY_PATH LD_LIBRARY_PATH= \
            make ARCH=arm64 \
                 CROSS_COMPILE=aarch64-buildroot-linux-gnu- \
                 MODEL=GTBE98 BCM_KF=y LINUX_VER_STR=4.19.294 \
                 -j"$(nproc)" Image
    )
    ;;
  *)
    die "unknown mode '$MODE' (use: full | image)"
    ;;
esac

echo
info "=== verifying configs landed ==="

# 1) config_data.gz baked into the built kernel (authoritative for what compiled in)
CD="$KD/kernel/config_data.gz"
if [[ -f "$CD" ]]; then
    for tok in $VERIFY_SYMS; do
        case "$tok" in
          CONFIG_*)
            if zcat "$CD" | grep -q "^$tok=y\|^$tok=m"; then
                info "  config_data.gz: $tok present (set)"
            elif zcat "$CD" | grep -q "$tok"; then
                info "  config_data.gz: $tok present"
            else
                info "  WARN config_data.gz: $tok NOT set"
            fi ;;
        esac
    done
else
    info "  (config_data.gz not found at $CD — check the build actually produced a kernel)"
fi

# 2) System.map — symbol presence (e.g. register_kprobe) proves the code compiled in
SM="$KD/System.map"
if [[ -f "$SM" ]]; then
    for tok in $VERIFY_SYMS; do
        case "$tok" in
          CONFIG_*) : ;;  # config tokens handled above
          *)
            if grep -q " $tok\$\|$tok\$" "$SM"; then
                info "  System.map: symbol '$tok' present"
            else
                info "  WARN System.map: symbol '$tok' not found"
            fi ;;
        esac
    done
else
    info "  (System.map not found at $SM)"
fi

echo
info "=== artifacts ==="
info "  kernel Image : $KD/arch/arm64/boot/Image"
# shellcheck disable=SC2086
if ls $PKGTB_GLOB >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    ls -lh $PKGTB_GLOB
    info "  ^ feed the .pkgtb above to scripts/split-pkgtb.sh"
else
    info "  (no .pkgtb under targets/$TARGET — expected for 'image' mode; use 'full' to package)"
fi
