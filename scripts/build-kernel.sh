#!/usr/bin/env bash
# build-kernel.sh — build the merlin 4.19 GT-BE98 kernel on dev-build via rtk.
#
# IMPORTANT: builds run on dev-build (10.0.50.21), NEVER on dev-code. This
# script is meant to be run ON dev-build (or it will SSH there for you with
# --remote). Run configure-kernel.sh FIRST to produce $KD/.config.
#
# Three modes:
#   kernel (default) — KERNEL-SPACE ONLY: kernel Image + all .ko modules, via the
#                      SDK's `recipe_kernel` phase. Does NOT build userspace tools
#                      (libnl, router daemons) — those belong to the rootfs build.
#                      This is the kernel repo's proper deliverable. The kernel
#                      can't build truly standalone (BCM_KF compiles bcmdrivers in),
#                      so this reuses the firmware's build env (toolchain etc.).
#   full             — drives ~/be98/gt-be98-firmware/build.sh (kernel + userspace
#                      + .pkgtb). A firmware-level build; produces the flashable
#                      .pkgtb. Use when you want the whole image.
#   image            — standalone `make Image` (FRAGILE/best-effort; the vendor
#                      kernel resists standalone builds — prefer `kernel`).
#
# After building it VERIFIES the requested configs landed (config_data.gz +
# System.map) and prints any .pkgtb.
#
# Usage (on dev-build):
#   scripts/build-kernel.sh                       # kernel + modules (recipe_kernel)
#   scripts/build-kernel.sh kernel
#   scripts/build-kernel.sh full                  # whole firmware -> .pkgtb
#   VERIFY_SYMS="CONFIG_KPROBES register_kprobe" scripts/build-kernel.sh
#
# Usage (from dev-code, dispatch to dev-build over SSH):
#   scripts/build-kernel.sh --remote [kernel|full|image]
#
# Env: FW SDKDIR KD (see kernel-env.sh), plus
#   TARGET   default 96813GW
#   DEVBUILD default guillaume@10.0.50.21   (for --remote)
#   RTK      default rtk        (set to "" to run make without the filter)
#   VERIFY_SYMS  default "CONFIG_KPROBES CONFIG_KALLSYMS_ALL"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

TARGET="${TARGET:-96813GW}"
DEVBUILD="${DEVBUILD:-guillaume@10.0.50.21}"
RTK="${RTK:-rtk}"
VERIFY_SYMS="${VERIFY_SYMS:-CONFIG_KPROBES CONFIG_KALLSYMS_ALL}"

info() { echo "build-kernel: $*"; }
die()  { echo "build-kernel: ERROR: $*" >&2; exit 1; }

# --remote: re-dispatch this script on dev-build (used from dev-code).
if [[ "${1:-}" == "--remote" ]]; then
    shift
    mode="${1:-kernel}"
    FW="${FW:-$HOME/be98/gt-be98-firmware}"
    REPO_REMOTE="${REPO_REMOTE:-$HOME/be98/gt-be98-kernel}"
    info "dispatching to $DEVBUILD: build-kernel.sh $mode"
    exec ssh "$DEVBUILD" "VERIFY_SYMS='$VERIFY_SYMS' '$REPO_REMOTE/scripts/build-kernel.sh' '$mode'"
fi

# Local (on dev-build): set up the GT-BE98 kernel env.
# shellcheck source=scripts/kernel-env.sh
source "$HERE/kernel-env.sh"

MODE="${1:-kernel}"
[[ -f "$KD/.config" ]] || die "no $KD/.config — run scripts/configure-kernel.sh first"

PKGTB_GLOB="$SDKDIR/targets/$TARGET/GT-BE98_*_nand_squashfs.pkgtb"

run() {
    if [[ -n "$RTK" ]] && command -v "$RTK" >/dev/null 2>&1; then
        "$RTK" "$@"
    else
        "$@"
    fi
}

case "$MODE" in
  kernel)
    # KERNEL-SPACE ONLY: kernel Image + all .ko modules (incl. =m bcmdrivers),
    # via the SDK's own `recipe_kernel` phase (= modbuild + dtbs +
    # prepare_linux_image). Does NOT build userspace tools (libnl, router
    # daemons) — those are a rootfs/firmware concern (the `userspace` phase).
    # This is the kernel repo's proper deliverable. Reuses the firmware's build
    # env (toolchain, host-env sanitize) exactly like build.sh.
    info "KERNEL-SPACE build (recipe_kernel): kernel Image + .ko modules, NO userspace"
    [[ -d "$FW/tools" ]] || die "firmware tools/ not found under $FW (need its env scripts)"
    export GTBE98_ROOT="$FW"
    export GTBE98_TC_ROOT="$FW/toolchain/am-toolchains/brcm-arm-hnd"
    # shellcheck source=/dev/null
    source "$FW/tools/sanitize-host-env.sh"; gtbe98_sanitize_ld_library_path
    # shellcheck source=/dev/null
    source "$FW/tools/env.sh"; gtbe98_sanitize_ld_library_path
    run env -u LD_LIBRARY_PATH make -C "$SDKDIR" FORCE=1 SHELL=/bin/bash \
        GTBE98_TC_ROOT="$GTBE98_TC_ROOT" GTBE98_ROOT="$GTBE98_ROOT" LD_LIBRARY_PATH= \
        PROFILE="$TARGET" recipe_kernel
    ;;
  full)
    info "FULL firmware build via $FW/build.sh (kernel + userspace + .pkgtb)"
    [[ -x "$FW/build.sh" ]] || die "$FW/build.sh not found/executable"
    # build.sh's profile_saved_check guard can fire once on FORCE=1 and exit 1
    # (it touches .last_profile then bails). Retry once on that benign first-run.
    if ! run "$FW/build.sh"; then
        info "build.sh exited non-zero (likely the profile_saved_check guard on FORCE=1) — retrying once"
        run "$FW/build.sh"
    fi
    ;;
  image)
    info "STANDALONE 'make Image' (FRAGILE/best-effort — prefer 'kernel'); $KD"
    [[ -n "${TCDIR:-}" && -d "$TCDIR" ]] || die "crosstools bin not found (set TCDIR)"
    # BCM_KF=y makes the kernel Makefile `include $(PROFILE_DIR)/../../kernel/
    # bcmkernel/Makefile.brcm_pre`, which pulls bcmdrivers into the build and
    # needs the SDK layout vars below (see docs/build-internals.md §5). Without
    # them the include path collapses to "/../../kernel/...". This is best-effort:
    # the authoritative packaged build is `full` (build.sh sets all of this).
    # NOTE: kmake is a shell function (rtk can't exec it), so call make directly.
    run make -C "$KD" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        MODEL="$MODEL" BCM_KF="$BCM_KF" LINUX_VER_STR="$LINUX_VER_STR" \
        BRCM_CHIP="${BRCM_CHIP:-6813}" BCM_CHIP="${BCM_CHIP:-6813}" \
        PROFILE_DIR="$SDKDIR/targets/$TARGET" \
        PROJECT_DIR="$SDKDIR/targets/$TARGET" \
        BUILD_DIR="$SDKDIR" \
        KERNEL_DIR="$KD" TOPDIR="$KD" \
        BRCMDRIVERS_DIR="$SDKDIR/bcmdrivers" \
        BRCMDRIVERS_DIR_RELATIVE=../../bcmdrivers \
        SHARED_DIR="$SDKDIR/shared" \
        -j"$(nproc)" Image
    ;;
  *)
    die "unknown mode '$MODE' (use: kernel | full | image)"
    ;;
esac

echo
info "=== verifying configs landed ==="
CD="$KD/kernel/config_data.gz"
if [[ -f "$CD" ]]; then
    for tok in $VERIFY_SYMS; do
        case "$tok" in
          CONFIG_*)
            if zcat "$CD" 2>/dev/null | grep -Eq "^$tok=(y|m)"; then
                info "  config_data.gz: $tok present (set)"
            elif zcat "$CD" 2>/dev/null | grep -q "$tok"; then
                info "  config_data.gz: $tok present"
            else
                info "  WARN config_data.gz: $tok NOT set"
            fi ;;
        esac
    done
else
    info "  (config_data.gz not found at $CD — check the build actually produced a kernel)"
fi

SM="$KD/System.map"
if [[ -f "$SM" ]]; then
    for tok in $VERIFY_SYMS; do
        case "$tok" in
          CONFIG_*) : ;;
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
