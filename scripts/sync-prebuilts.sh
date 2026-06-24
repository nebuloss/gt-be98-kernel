#!/usr/bin/env bash
# sync-prebuilts.sh — make the full firmware build (build.sh -> .pkgtb) possible
# on a vendor tree that is MISSING closed Broadcom prebuilt objects.
#
# The gnuton-based gt-be98-firmware SDK ships some prebuilt blobs (dhd/wl/hnd/...)
# but NOT others the full build needs (bcm_bpm.o, cmdlist.o, bcmvlan.o,
# pktflow.o, rdpa_*.o, unimac_drv_impl1.o, ...). They have no source. They are,
# however, present in a sibling RMerl checkout of the SAME SDK version and ARE
# ABI-compatible (verified: a full pkgtb built cleanly after syncing them).
#
# This script copies every prebuilt .o from a REFERENCE SDK's bcmdrivers that our
# tree lacks, but ONLY where no same-name .c exists in the target dir (so it never
# shadows an open-source file our build compiles itself). It also (with --clean-
# libtool) clears stale libtool state that pruning leaves behind (empty .libs/
# dirs with surviving .lo/.la), which otherwise breaks userspace relinks (libnl).
#
# Runs on dev-build. Idempotent.
#
# Usage:
#   scripts/sync-prebuilts.sh                 # copy missing prebuilt .o from $REF_SDK
#   scripts/sync-prebuilts.sh --clean-libtool # also clean stale libtool dirs under wl/
#   REF_SDK=/path/to/other/src-rt-5.04behnd.4916 scripts/sync-prebuilts.sh
#
# Env: SDKDIR (our tree, from kernel-env.sh), REF_SDK (reference SDK with the blobs)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kernel-env.sh
source "$HERE/kernel-env.sh"

REF_SDK="${REF_SDK:-$HOME/re-sdk/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"
die()  { echo "sync-prebuilts: ERROR: $*" >&2; exit 1; }
info() { echo "sync-prebuilts: $*"; }

CLEAN_LIBTOOL=0
[[ "${1:-}" == "--clean-libtool" ]] && CLEAN_LIBTOOL=1

RB="$REF_SDK/bcmdrivers"
OB="$SDKDIR/bcmdrivers"
[[ -d "$RB" ]] || die "reference SDK bcmdrivers not found: $RB (set REF_SDK)"
[[ -d "$OB" ]] || die "our bcmdrivers not found: $OB"

info "reference: $RB"
info "target:    $OB"

copied=0; skipped_have=0; skipped_src=0
while IFS= read -r f; do
    rel="${f#"$RB"/}"; d="$(dirname "$rel")"; base="$(basename "$rel" .o)"
    if [[ -f "$OB/$rel" ]]; then skipped_have=$((skipped_have+1)); continue; fi
    if [[ -f "$OB/$d/$base.c" ]]; then skipped_src=$((skipped_src+1)); continue; fi
    mkdir -p "$OB/$d"
    cp -p "$f" "$OB/$rel" && copied=$((copied+1))
done < <(find "$RB" -name '*.o' 2>/dev/null)

info "copied $copied prebuilt object(s) (already-present: $skipped_have, have-source: $skipped_src)"

if (( CLEAN_LIBTOOL )); then
    info "cleaning stale libtool state under bcmdrivers/broadcom/net/wl ..."
    n=0
    while IFS= read -r libs; do
        d="$(dirname "$libs")"
        # stale == .libs/ exists but is empty AND sibling .lo files exist
        if [[ -z "$(ls -A "$libs" 2>/dev/null)" ]] && ls "$d"/*.lo >/dev/null 2>&1; then
            find "$d" -maxdepth 1 \( -name '*.lo' -o -name '*.la' -o -name '.dirstamp' \) -delete 2>/dev/null || true
            rm -rf "$d/.libs" "$d/.deps" 2>/dev/null || true
            n=$((n+1))
        fi
    done < <(find "$SDKDIR/bcmdrivers/broadcom/net/wl" -type d -name '.libs' 2>/dev/null)
    info "cleaned $n stale libtool dir(s)"
fi

info "done. Now: scripts/configure-kernel.sh <frag>  &&  scripts/build-kernel.sh full"
