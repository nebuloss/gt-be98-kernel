#!/usr/bin/env bash
# kernel-env.sh — the host + kbuild environment the GT-BE98 merlin 4.19 kernel
# needs for ANY standard kconfig/build command (olddefconfig, menuconfig,
# savedefconfig, merge_config.sh, make Image, ...).
#
# SOURCE this; it does not exec anything:   source scripts/kernel-env.sh
# It exports KD, defines kmake(), and fixes PATH / LD_LIBRARY_PATH.
#
# This file encodes the four things that were reverse-engineered the hard way
# (see docs/build-internals.md). All four are *environment*, not kernel-source
# constraints — get them right and the kernel behaves like a normal kernel:
#
#   1. Host tools (bison/flex/gcc) MUST come first on PATH. The crosstools
#      */usr/bin also ship a bison that needs libreadline.so.6 (absent on a
#      modern distro) — if it shadows the host bison, kconfig won't even build.
#   2. LD_LIBRARY_PATH must be UNSET. Crosstools lib/ breaks the host gcc/cc1.
#   3. BCM_KF=y so Kconfig.bcmconfig sources ../bcmkernel/Kconfig.bcm_kf* — the
#      ~68 CONFIG_BCM_KF_* and ~190 CONFIG_BCM_* symbols only exist when BCM_KF=y.
#      (Building config WITHOUT BCM_KF=y is what historically "stripped" them.)
#   4. LINUX_VER_STR=4.19.294 (Kconfig sources Kconfig.bcm_kf.$(LINUX_VER_STR))
#      and MODEL=GTBE98 (top Makefile does -D$(MODEL); a bare -D errors out).
#
# Env overrides (all have sane defaults):
#   FW       firmware root            default ~/be98/gt-be98-firmware
#   SDKDIR   merlin SDK               default $FW/vendor/.../src-rt-5.04behnd.4916
#   KD       kernel tree             default $SDKDIR/kernel/linux-4.19
#   TCDIR    crosstools bin dir       default auto-detected under the toolchain
#   ARCH MODEL BCM_KF LINUX_VER_STR CROSS_COMPILE   (kbuild knobs; defaulted)

# Not set -euo here: this file is sourced into callers that manage their own set.

FW="${FW:-$HOME/be98/gt-be98-firmware}"
SDKDIR="${SDKDIR:-$FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"
KD="${KD:-$SDKDIR/kernel/linux-4.19}"
export FW SDKDIR KD

# kbuild knobs (the four-flag set that makes regen safe + non-interactive).
ARCH="${ARCH:-arm64}"
MODEL="${MODEL:-GTBE98}"
BCM_KF="${BCM_KF:-y}"
LINUX_VER_STR="${LINUX_VER_STR:-4.19.294}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-buildroot-linux-gnu-}"
export ARCH MODEL BCM_KF LINUX_VER_STR CROSS_COMPILE

# Locate the aarch64 crosstools bin (needed for compiles; harmless for config).
if [[ -z "${TCDIR:-}" ]]; then
    TCDIR="$FW/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1/bin"
    if [[ ! -d "$TCDIR" ]]; then
        # Fallback: first aarch64 crosstools bin we can find.
        TCDIR="$(ls -d "$FW"/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-*/bin 2>/dev/null | head -1)"
    fi
fi
export TCDIR

# (1) host tools first, (2) no crosstool libs on the loader path.
unset LD_LIBRARY_PATH
if [[ -n "$TCDIR" && -d "$TCDIR" ]]; then
    export PATH="/usr/bin:/bin:$TCDIR:$PATH"
else
    export PATH="/usr/bin:/bin:$PATH"
fi

# kmake: run the kernel's make with the GT-BE98 kbuild env already applied.
# Use this for olddefconfig / menuconfig / savedefconfig / <name>_defconfig /
# merge / Image, e.g.:  kmake olddefconfig   |   kmake -j"$(nproc)" Image
kmake() {
    make -C "$KD" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
         MODEL="$MODEL" BCM_KF="$BCM_KF" LINUX_VER_STR="$LINUX_VER_STR" "$@"
}

kernel_env_summary() {
    echo "kernel-env: KD=$KD"
    echo "kernel-env: ARCH=$ARCH MODEL=$MODEL BCM_KF=$BCM_KF LINUX_VER_STR=$LINUX_VER_STR"
    echo "kernel-env: TCDIR=${TCDIR:-<none>} (host tools first on PATH; LD_LIBRARY_PATH cleared)"
}
