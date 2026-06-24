#!/usr/bin/env bash
# configure-kernel.sh — produce the GT-BE98 kernel .config the STANDARD kbuild
# way: seed from a tracked base defconfig, merge any config fragments, then
# `make olddefconfig`. Writes $KD/.config, ready for build-kernel.sh.
#
#     configs/gtbe98_defconfig   --(make gtbe98_defconfig)-->  .config
#       + config-fragments/*     --(merge_config.sh)------->  .config
#                                --(make olddefconfig)------>  .config (final)
#
# This REPLACES the old in-place sed editing of config_base.6a.6813. There is no
# longer any need to:
#   * avoid olddefconfig (it is safe + REQUIRED here — with BCM_KF=y it keeps all
#     ~68 CONFIG_BCM_KF_* / ~190 CONFIG_BCM_* symbols; see docs/build-internals.md),
#   * hand-pin newly-exposed symbols (olddefconfig resolves them to defaults
#     non-interactively — no "(NEW)" prompts, no "Unexpected EOF"),
#   * keep a .orig backup of an SDK file (the durable source is now the
#     version-controlled configs/gtbe98_defconfig in THIS repo).
#
# Runs on dev-build (where the kernel tree + host toolchain live).
#
# Usage:
#   scripts/configure-kernel.sh                                   # stock base only
#   scripts/configure-kernel.sh config-fragments/kprobes.fragment # base + fragment(s)
#   scripts/configure-kernel.sh -m  [fragments...]                # then open menuconfig
#
# Env (see scripts/kernel-env.sh for the full list): FW SDKDIR KD, plus
#   BASE_DEFCONFIG  default <repo>/configs/gtbe98_defconfig
#   DEFCONFIG_NAME  default gtbe98_defconfig  (installed into arch/$ARCH/configs/)
#   VERIFY_SYMS     space-separated CONFIG_ tokens to report after (default kprobes set)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=scripts/kernel-env.sh
source "$HERE/kernel-env.sh"

BASE_DEFCONFIG="${BASE_DEFCONFIG:-$REPO/configs/gtbe98_defconfig}"
DEFCONFIG_NAME="${DEFCONFIG_NAME:-gtbe98_defconfig}"
VERIFY_SYMS="${VERIFY_SYMS:-CONFIG_KPROBES CONFIG_KALLSYMS_ALL}"

die()  { echo "configure-kernel: ERROR: $*" >&2; exit 1; }
info() { echo "configure-kernel: $*"; }

OPEN_MENUCONFIG=0
FRAGMENTS=()
for arg in "$@"; do
    case "$arg" in
        -m|--menuconfig) OPEN_MENUCONFIG=1 ;;
        -*)              die "unknown option: $arg" ;;
        *)               [[ -f "$arg" ]] || die "fragment not found: $arg"; FRAGMENTS+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")") ;;
    esac
done

[[ -d "$KD" ]]             || die "kernel tree not found: $KD (set SDKDIR/KD)"
[[ -f "$BASE_DEFCONFIG" ]] || die "base defconfig not found: $BASE_DEFCONFIG"
MERGE="$KD/scripts/kconfig/merge_config.sh"
[[ -f "$MERGE" ]]          || die "merge_config.sh not found in kernel tree"

kernel_env_summary
info "base defconfig : $BASE_DEFCONFIG"
info "fragments      : ${FRAGMENTS[*]:-<none>}"

# 1) Seed .config from the tracked base defconfig. We install it under
#    arch/$ARCH/configs/ so the standard `make <name>_defconfig` target works.
install -m 0644 "$BASE_DEFCONFIG" "$KD/arch/$ARCH/configs/$DEFCONFIG_NAME"
info "seeding .config via: make $DEFCONFIG_NAME"
kmake "$DEFCONFIG_NAME" >/dev/null

# 2) Merge fragments with the kernel's own tool (-m = merge only; we run the
#    make step ourselves in step 3). Later files win on conflict (it warns).
if (( ${#FRAGMENTS[@]} )); then
    info "merging ${#FRAGMENTS[@]} fragment(s) with merge_config.sh -m"
    ( cd "$KD" && ARCH="$ARCH" bash "$MERGE" -m -O "$KD" "$KD/.config" "${FRAGMENTS[@]}" )
fi

# 3) Settle: olddefconfig resolves every (possibly newly-exposed) symbol to its
#    default, non-interactively. This is the step the old doc wrongly warned off.
info "make olddefconfig (resolve defaults, non-interactive)"
kmake olddefconfig >/dev/null

# Report.
echo
info "=== resulting $KD/.config ==="
info "  CONFIG_BCM_KF_*=y/m : $(grep -cE '^CONFIG_BCM_KF.*=[ym]' "$KD/.config")  (expect ~68 — proves BCM_KF preserved)"
info "  CONFIG_BCM_*  =y/m  : $(grep -cE '^CONFIG_BCM_.*=[ym]'   "$KD/.config")"
for tok in $VERIFY_SYMS; do
    if grep -qE "^$tok=[ym]" "$KD/.config"; then
        info "  $(grep -E "^$tok=" "$KD/.config")"
    else
        info "  $tok : not set"
    fi
done

if (( OPEN_MENUCONFIG )); then
    info "launching menuconfig (edits .config in place)"
    kmake menuconfig
    info "menuconfig done. To persist changes into the repo base, run: scripts/save-defconfig.sh"
fi

echo
info "done. .config is ready — build with: scripts/build-kernel.sh [full|image]"
