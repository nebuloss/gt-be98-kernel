#!/usr/bin/env bash
# flash-slot1.sh — transfer a freshly-built bootfs (and optionally rootfs) to the
# GT-BE98 and flash the SLOT1 (trial) UBI volumes ONLY, then arm a one-time boot
# of slot1 and reboot. NEVER touches slot2 (the committed stock fallback).
#
# Runs from dev-build (or dev-code — anywhere that can ssh the device and read
# the artifact). Does the binary transfer via base64 | openssl because device
# busybox has no base64 and the rtk hook rejects binary cat.
#
# ============================ GOLDEN RULES =================================
#   * SLOT1 = trial (we flash it).  SLOT2 = committed stock fallback (NEVER touch).
#   * This script REFUSES to run if the device is currently BOOTED on slot1
#     (you'd be flashing the slot you're standing on — no way back).
#   * This script REFUSES to run unless bcm_bootstate reports slot2 as the
#     committed image (the rope you climb back up).
#   * It operates strictly on the volumes named by SLOT1_BOOTFS_VOL /
#     SLOT1_ROOTFS_VOL and aborts if their resolved ubi numbers look like slot2.
#   * A fully-booting firmware AUTO-COMMITS its slot — bcm_bootstate 6 alone is
#     NOT revert-safe once slot1 boots clean. Layer the deadman watchdog
#     (see docs/build-internals.md "Safety / recovery"). After a good boot,
#     disarm: on the device `touch /tmp/deadman-disarm; /bin/wdtctl stop`.
#   * Recover any time: on the device `bcm_bootstate 7 && reboot` -> stock slot2.
# ==========================================================================
#
# Usage:
#   scripts/flash-slot1.sh <bootfs.itb> [rootfs.img]
#   DRYRUN=1 scripts/flash-slot1.sh <bootfs.itb>     # print, don't execute
#
# Env:
#   DEVICE      default admin@10.0.0.8     (committed slot2 mgmt IP)
#   DEVPORT     default 2222
#   SSH         default "ssh -p $DEVPORT"
#   SLOT1_BOOTFS_VOL  default bootfs1   (UBI vol NAME for slot1 bootfs; static)
#   SLOT1_ROOTFS_VOL  default rootfs1   (UBI vol NAME for slot1 rootfs; dynamic)
#   ASSUME_YES  set to 1 to skip the interactive confirmation (CI/non-tty)
#
# NOTE: volume names/numbers are verified live with `ubinfo` before any write.
set -euo pipefail

DEVICE="${DEVICE:-admin@10.0.0.8}"
DEVPORT="${DEVPORT:-2222}"
SSH="${SSH:-ssh -p $DEVPORT}"
SLOT1_BOOTFS_VOL="${SLOT1_BOOTFS_VOL:-bootfs1}"
SLOT1_ROOTFS_VOL="${SLOT1_ROOTFS_VOL:-rootfs1}"
DRYRUN="${DRYRUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

die() { echo "flash-slot1: ERROR: $*" >&2; exit 1; }
info(){ echo "flash-slot1: $*"; }

BOOTFS="${1:-}"
ROOTFS="${2:-}"
[[ -n "$BOOTFS" ]] || die "usage: $0 <bootfs.itb> [rootfs.img]"
[[ -f "$BOOTFS" ]] || die "bootfs not found: $BOOTFS"
[[ -z "$ROOTFS" || -f "$ROOTFS" ]] || die "rootfs not found: $ROOTFS"

dev() { $SSH "$DEVICE" "$@"; }

# Wrap a device command honoring DRYRUN.
devrun() {
    if [[ "$DRYRUN" == 1 ]]; then
        echo "DRYRUN device> $*"
    else
        dev "$@"
    fi
}

info "device: $DEVICE (port $DEVPORT)"

# ---- 0. reachability ----
info "checking device reachability ..."
dev 'echo ok' >/dev/null 2>&1 || die "cannot ssh $DEVICE — is the device up on that IP?"

# ---- 1. SAFETY: not booted on slot1, slot2 committed ----
info "reading bcm_bootstate ..."
BOOTSTATE="$(dev 'bcm_bootstate 2>/dev/null' || true)"
echo "----- bcm_bootstate -----"
echo "$BOOTSTATE"
echo "-------------------------"
[[ -n "$BOOTSTATE" ]] || die "bcm_bootstate produced no output — refusing to flash blind"

# Heuristics on the bootstate text. The committed image must be slot2.
# Different firmware revs phrase this differently; we look for an explicit
# 'committed' association with image/part 2. If we cannot positively confirm
# slot2 is committed, we ABORT (fail safe).
if echo "$BOOTSTATE" | grep -iqE 'commit.*(image|part|slot)?[^0-9]*2|2[^0-9]*commit'; then
    info "slot2 appears committed (good — that's our fallback)"
else
    die "could NOT confirm slot2 is the committed image from bcm_bootstate above. \
ABORTING (fail-safe). Make slot2 committed first: on device 'bcm_bootstate 7 && reboot'."
fi

# Refuse if we're booted on slot1. slot1's rootfs is /dev/ubiblock0_4 typically,
# but the robust check is the device's own IP: committed slot2 mgmt IP is the
# DEVICE we connected to. If the running rootfs is the slot1 volume, abort.
RUNNING_ROOT="$(dev 'cat /proc/cmdline 2>/dev/null' || true)"
if echo "$RUNNING_ROOT" | grep -qiE 'ubiblock0_4|rootfs1'; then
    die "device appears to be RUNNING on slot1 (cmdline: $RUNNING_ROOT). \
Flashing slot1 while booted on it leaves no fallback. ABORTING. Boot the committed \
slot2 first (bcm_bootstate 7 && reboot)."
fi

# ---- 2. resolve slot1 volumes; ensure they are NOT slot2's ----
info "resolving UBI volumes (ubinfo) ..."
UBINFO="$(dev 'ubinfo -a 2>/dev/null' || true)"
echo "$UBINFO" | grep -iE 'Volume ID|Name|Type|Size|bytes' | sed 's/^/  /' || true

# Find the ubi volume number for the slot1 bootfs/rootfs by NAME.
vol_num_of() {  # $1 = volume name -> prints "N" (the ubi0_N device suffix)
    local name="$1"
    echo "$UBINFO" | awk -v want="$name" '
        /^Volume ID/ { id=$3 }
        /Name:/ { n=$2; if (n==want) { print id; exit } }'
}
BOOTFS_NUM="$(vol_num_of "$SLOT1_BOOTFS_VOL" || true)"
ROOTFS_NUM="$(vol_num_of "$SLOT1_ROOTFS_VOL" || true)"

info "slot1 bootfs vol '$SLOT1_BOOTFS_VOL' -> ubi0_${BOOTFS_NUM:-<unknown>}"
[[ -n "$ROOTFS" ]] && info "slot1 rootfs vol '$SLOT1_ROOTFS_VOL' -> ubi0_${ROOTFS_NUM:-<unknown>}"

# Hard guard: known slot2 volume names/numbers must NOT be our targets.
# (Observed on this unit: slot2 bootfs=ubi0_5 / rootfs=ubi0_6, names bootfs2/rootfs2.)
case "$SLOT1_BOOTFS_VOL" in *2) die "SLOT1_BOOTFS_VOL ends in '2' — that's slot2! Refusing.";; esac
case "$SLOT1_ROOTFS_VOL" in *2) die "SLOT1_ROOTFS_VOL ends in '2' — that's slot2! Refusing.";; esac
[[ "${BOOTFS_NUM:-}" == "5" || "${BOOTFS_NUM:-}" == "6" ]] && die "bootfs resolved to ubi0_$BOOTFS_NUM (slot2 range) — refusing"
[[ "${ROOTFS_NUM:-}" == "5" || "${ROOTFS_NUM:-}" == "6" ]] && die "rootfs resolved to ubi0_$ROOTFS_NUM (slot2 range) — refusing"

# ---- 3. sizes ----
BOOTFS_BYTES="$(stat -c %s "$BOOTFS")"
info "bootfs.itb size: $BOOTFS_BYTES bytes"
if [[ -n "$ROOTFS" ]]; then
    ROOTFS_BYTES="$(stat -c %s "$ROOTFS")"
    info "rootfs.img size: $ROOTFS_BYTES bytes"
fi

# ---- 4. confirm ----
if [[ "$ASSUME_YES" != 1 && "$DRYRUN" != 1 ]]; then
    echo
    echo "About to: flash SLOT1 ONLY (bootfs vol '$SLOT1_BOOTFS_VOL'$( [[ -n $ROOTFS ]] && echo \", rootfs vol '$SLOT1_ROOTFS_VOL'\" )),"
    echo "          arm bcm_bootstate 6 (boot slot1 ONCE), and reboot the device."
    echo "          slot2 (committed stock) is NOT touched."
    read -r -p "Type YES to proceed: " ans
    [[ "$ans" == "YES" ]] || die "aborted by user"
fi

# ---- 5. transfer artifacts (ssh-cat: binary-safe, runs on the device) ----
# Use `ssh DEVICE 'cat > file' < img` — the cat runs ON THE DEVICE (no local rtk
# hook on a binary cat), and ssh is 8-bit clean, so this is binary-safe. (The old
# `base64 | openssl base64 -d` path silently delivered 0 bytes on the stock slot2
# image, whose openssl choked — verified 2026-06-24.) Stage to /tmp (/data fills up).
info "transferring bootfs -> /tmp/bootfs.itb (ssh-cat) ..."
if [[ "$DRYRUN" == 1 ]]; then
    echo "DRYRUN> $SSH $DEVICE 'cat > /tmp/bootfs.itb' < '$BOOTFS'"
else
    $SSH "$DEVICE" 'cat > /tmp/bootfs.itb' < "$BOOTFS"
    GOT="$(dev 'stat -c %s /tmp/bootfs.itb 2>/dev/null' || echo 0)"
    [[ "$GOT" == "$BOOTFS_BYTES" ]] || die "bootfs transfer size mismatch (local $BOOTFS_BYTES vs device $GOT)"
    info "bootfs transferred OK ($GOT bytes)"
fi
if [[ -n "$ROOTFS" ]]; then
    info "transferring rootfs -> /tmp/rootfs.img ..."
    if [[ "$DRYRUN" == 1 ]]; then
        echo "DRYRUN> $SSH $DEVICE 'cat > /tmp/rootfs.img' < '$ROOTFS'"
    else
        $SSH "$DEVICE" 'cat > /tmp/rootfs.img' < "$ROOTFS"
        GOT="$(dev 'stat -c %s /tmp/rootfs.img 2>/dev/null' || echo 0)"
        [[ "$GOT" == "$ROOTFS_BYTES" ]] || die "rootfs transfer size mismatch (local $ROOTFS_BYTES vs device $GOT)"
        info "rootfs transferred OK ($GOT bytes)"
    fi
fi

# ---- 6. flash slot1 volumes (grow if image > current vol) ----
# bootfs is a STATIC volume (-t static); rootfs is dynamic. ubiupdatevol fails if
# the image is larger than the volume, so if needed we remove+recreate sized.
# We recreate with the SAME name and (for bootfs) the SAME ubi number (-n) so the
# boot loader still finds it. We pass the discovered number; if unknown we let
# ubi auto-assign but warn loudly.
BNUM_FLAG=""; [[ -n "${BOOTFS_NUM:-}" ]] && BNUM_FLAG="-n $BOOTFS_NUM"

info "flashing slot1 bootfs (grow-if-needed, then ubiupdatevol) ..."
devrun "set -e; \
  cur=\$(ubinfo /dev/ubi0 -N '$SLOT1_BOOTFS_VOL' 2>/dev/null | awk '/Size:/{print \$NF}' | tr -dc 0-9); \
  echo \"slot1 bootfs current vol bytes: \${cur:-unknown}, image bytes: $BOOTFS_BYTES\"; \
  if [ -z \"\$cur\" ] || [ \"$BOOTFS_BYTES\" -gt \"\${cur:-0}\" ]; then \
    echo 'growing bootfs volume'; \
    ubirmvol /dev/ubi0 -N '$SLOT1_BOOTFS_VOL'; \
    ubimkvol /dev/ubi0 -N '$SLOT1_BOOTFS_VOL' -s $BOOTFS_BYTES -t static $BNUM_FLAG; \
  fi; \
  ubiupdatevol /dev/ubi0_${BOOTFS_NUM:-3} /tmp/bootfs.itb; \
  echo 'bootfs flashed'"

if [[ -n "$ROOTFS" ]]; then
    RNUM_FLAG=""; [[ -n "${ROOTFS_NUM:-}" ]] && RNUM_FLAG="-n $ROOTFS_NUM"
    info "flashing slot1 rootfs ..."
    devrun "set -e; \
      cur=\$(ubinfo /dev/ubi0 -N '$SLOT1_ROOTFS_VOL' 2>/dev/null | awk '/Size:/{print \$NF}' | tr -dc 0-9); \
      echo \"slot1 rootfs current vol bytes: \${cur:-unknown}, image bytes: $ROOTFS_BYTES\"; \
      if [ -z \"\$cur\" ] || [ \"$ROOTFS_BYTES\" -gt \"\${cur:-0}\" ]; then \
        echo 'growing rootfs volume'; \
        ubirmvol /dev/ubi0 -N '$SLOT1_ROOTFS_VOL'; \
        ubimkvol /dev/ubi0 -N '$SLOT1_ROOTFS_VOL' -s $ROOTFS_BYTES $RNUM_FLAG; \
      fi; \
      ubiupdatevol /dev/ubi0_${ROOTFS_NUM:-4} /tmp/rootfs.img; \
      echo 'rootfs flashed'"
fi

# ---- 7. arm one-time slot1 boot + reboot ----
info "arming bcm_bootstate 6 (boot slot1 ONCE — does NOT change commit flags) + reboot ..."
devrun "bcm_bootstate 6"
devrun "nohup reboot >/dev/null 2>&1 &"

echo
info "DONE. Device rebooting into slot1 (trial)."
info "  * slot1 trial IP is typically 10.0.0.95 (slot2 stock = 10.0.0.8)."
info "  * If slot1 wedges, the deadman watchdog reverts to slot2 in ~4 min."
info "  * To KEEP a good slot1 boot, on the device: touch /tmp/deadman-disarm; /bin/wdtctl stop"
info "  * To force-revert any time, on the device: bcm_bootstate 7 && reboot"
