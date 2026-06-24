#!/usr/bin/env bash
# save-defconfig.sh — regenerate the tracked base defconfig from the current
# $KD/.config using the standard `make savedefconfig` (minimal defconfig: only
# symbols that differ from their Kconfig default). Use after editing .config
# (e.g. via `configure-kernel.sh -m` / menuconfig) to persist the change into
# this repo.
#
# Runs on dev-build. Writes to <repo>/configs/gtbe98_defconfig by default; copy
# it back to dev-code and commit.
#
#   savedefconfig round-trips faithfully: expanding the minimal defconfig with
#   `make <name>_defconfig` + olddefconfig (in the BCM_KF=y env) reproduces the
#   exact same symbol set. Verified against the known-good GT-BE98 config.
#
# Usage:
#   scripts/save-defconfig.sh                 # .config -> configs/gtbe98_defconfig
#   scripts/save-defconfig.sh /path/out.defconfig
#
# NOTE: whatever is currently in .config is folded in — including any fragment
# deltas. If you want the base to stay "stock", run this from a stock .config,
# and keep feature deltas as fragments in config-fragments/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=scripts/kernel-env.sh
source "$HERE/kernel-env.sh"

OUT="${1:-$REPO/configs/gtbe98_defconfig}"
die()  { echo "save-defconfig: ERROR: $*" >&2; exit 1; }
info() { echo "save-defconfig: $*"; }

[[ -f "$KD/.config" ]] || die "no $KD/.config — run configure-kernel.sh first"

kernel_env_summary
info "make savedefconfig from $KD/.config"
kmake savedefconfig >/dev/null   # writes $KD/defconfig
[[ -f "$KD/defconfig" ]] || die "savedefconfig produced no defconfig"

mkdir -p "$(dirname "$OUT")"
mv -f "$KD/defconfig" "$OUT"
info "wrote $OUT ($(wc -l < "$OUT") lines)"
info "review + commit it. If on dev-build, copy back to dev-code's checkout."
