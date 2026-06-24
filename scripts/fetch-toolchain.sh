#!/usr/bin/env bash
# fetch-toolchain.sh — fetch + extract a published gt-be98-toolchain variant
# (a Buildroot external-toolchain Release asset) into a local cache, and print
# the extracted bin/ dir on stdout. Lets the kernel build compile against the
# DEDICATED toolchain repo instead of the firmware-vendored RMerl clone.
#
# Validated: a recipe_kernel build forced onto the aarch64 variant (via
# KCROSS_COMPILE) produced a fresh GT-BE98 kernel Image. See build-kernel.sh's
# `kernel` mode with TC_FROM_RELEASE=1.
#
# Usage:
#   scripts/fetch-toolchain.sh [aarch64|arm_softfp]     # default aarch64
#   bindir=$(scripts/fetch-toolchain.sh aarch64)        # capture the bin/ path
#
# Env:
#   TC_CACHE   where to cache/extract (default ~/.cache/gt-be98-toolchain)
#   TC_BASEURL release download base (default the nebuloss repo)
#   GH_TOKEN_FILE  token file for private-repo downloads (default ~/.config/gt-be98/gh-token)
set -euo pipefail

VARIANT="${1:-aarch64}"
TC_CACHE="${TC_CACHE:-$HOME/.cache/gt-be98-toolchain}"
TC_BASEURL="${TC_BASEURL:-https://github.com/nebuloss/gt-be98-toolchain/releases/download}"
GH_TOKEN_FILE="${GH_TOKEN_FILE:-$HOME/.config/gt-be98/gh-token}"

die() { echo "fetch-toolchain: ERROR: $*" >&2; exit 1; }
log() { echo "fetch-toolchain: $*" >&2; }   # logs to stderr; stdout is the bin path

# variant -> release tag, asset name, pinned sha256 (empty = don't verify)
case "$VARIANT" in
  aarch64)
    TAG="aarch64-gcc10.3"; ASSET="gt-be98-toolchain-aarch64-gcc10.3.tar.gz"
    SHA="ffde9b4c2f3d6d6f8c05af1414c31e0d8617dbc0bd9116f3891383a99b42ed7e" ;;
  arm_softfp)
    TAG="arm_softfp-gcc10.3"; ASSET="gt-be98-toolchain-arm_softfp-gcc10.3.tar.gz"
    SHA="" ;;   # not pinned yet; will warn
  *) die "unknown variant '$VARIANT' (use: aarch64 | arm_softfp)" ;;
esac

URL="$TC_BASEURL/$TAG/$ASSET"
DEST="$TC_CACHE/$VARIANT"
BIN="$DEST/bin"
STAMP="$DEST/.fetched-$SHA"

# Already extracted with the expected sha? -> reuse.
if [[ -x "$BIN/aarch64-buildroot-linux-gnu-gcc" || -x "$BIN/arm-buildroot-linux-gnueabi-gcc" ]] \
   && { [[ -z "$SHA" ]] || [[ -f "$STAMP" ]]; }; then
    log "reusing cached $VARIANT toolchain at $DEST"
    echo "$BIN"; exit 0
fi

mkdir -p "$TC_CACHE"
TGZ="$TC_CACHE/$ASSET"
if [[ ! -f "$TGZ" ]]; then
    log "downloading $URL"
    # token only used if the asset needs auth; harmless for public releases.
    if [[ -f "$GH_TOKEN_FILE" ]]; then
        curl -fL --retry 3 -H "Authorization: Bearer $(cat "$GH_TOKEN_FILE")" -o "$TGZ" "$URL" \
            || curl -fL --retry 3 -o "$TGZ" "$URL"
    else
        curl -fL --retry 3 -o "$TGZ" "$URL"
    fi
fi

if [[ -n "$SHA" ]]; then
    have="$(sha256sum "$TGZ" | cut -d' ' -f1)"
    [[ "$have" == "$SHA" ]] || die "sha256 mismatch for $ASSET: got $have, want $SHA"
    log "sha256 OK"
else
    log "WARN: no pinned sha256 for $VARIANT — not verifying"
fi

log "extracting -> $DEST"
rm -rf "$DEST"; mkdir -p "$DEST"
# single top-level dir; strip it so bin/ lands at $DEST/bin (Buildroot layout)
tar -C "$DEST" --strip-components=1 -xzf "$TGZ"
[[ -d "$BIN" ]] || die "no bin/ after extract (unexpected tarball layout)"
[[ -n "$SHA" ]] && touch "$STAMP"
log "ready: $BIN"
echo "$BIN"
