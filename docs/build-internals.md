# GT-BE98 custom kernel — build internals (the hard-won knowledge)

Everything below was reverse-engineered by hand from the asuswrt-merlin SDK
(`src-rt-5.04behnd.4916`, profile `96813GW`, kernel **linux-4.19.294**) for the
ASUS GT-BE98 (BCM6726/6813, "behnd" merlin). It is the knowledge that took a day
to extract; preserve it. The scripts in this repo encode it so a new kernel
CONFIG can be added reproducibly instead of by hand.

> Topology: **dev-code** (10.0.50.20) = source + git ONLY, never build.
> **dev-build** (10.0.50.21) = all compiling, over SSH, wrapped in `rtk` to
> filter buildroot/kbuild spam. The merlin SDK lives on **both** at
> `~/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916`.

Path shorthand used throughout:
```
FW      = ~/be98/gt-be98-firmware
SDKDIR  = $FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
KD      = $SDKDIR/kernel/linux-4.19
TARGET  = 96813GW
```

---

## 1. The ONLY durable kernel-config source: `config_base.6a.6813`

The kernel `.config` is produced each build by COPYING a base file through a
chain. The chain (RE'd from the build makefiles):

```
config_base.6a.6813  --cp-->  config_gt-be98  --(symlink)-->  config_current
                     --cp-->  .config  --syncconfig-->  built kernel
```

The crucial step is `cp config_current .config`, which runs **every build** and
**clobbers** `.config`. Therefore editing any of these is **FUTILE** — all are
overwritten:

- `$KD/.config`                         (overwritten by `cp config_current .config`)
- `$KD/arch/arm64/defconfig`            (the `gendefconfig` fold-in is **commented
                                          out** at `build/pre_kernelbuild.mk:34`,
                                          so `.config` does NOT derive from it)
- `$SDKDIR/hostTools/scripts/defconfig-bcm.template`  (same — gendefconfig off)
- the profile `targets/96813GW/96813GW.GT-BE98`  (its `BRCM_KERNEL_*` knobs
                                          *would* be mapped by gendefconfig, but
                                          gendefconfig is disabled, so they are
                                          **inert** for the kernel `.config`)

> (An earlier doc, `gt-be98-open-ethernet/docs/custom-kernel-howto.md §2b`,
> described editing `defconfig-bcm.template` + `rm .pre_kernelbuild` as the
> "durable" path. That path is now known NOT to take for this SDK state because
> gendefconfig is commented out and `.config` is re-copied from `config_current`
> each build. **`config_base.6a.6813` is the real durable source.** This repo's
> `configure-kernel.sh` edits `config_base` and supersedes that older recipe.)

**The ONE durable injection point is `$KD/config_base.6a.6813`** — a Jun-16
source file the build does not regenerate. Edit IT.

> There is also a `config_base.6a.6764L` for a **different chip**. 6813 = our
> BCM6813 GT-BE98. Use the `.6813` file.

---

## 2. NEVER `olddefconfig` / `make clean` on config_base

Running `olddefconfig` (or any config regeneration) on `config_base.6a.6813`
strips ~64 `CONFIG_BCM_KF_*` symbols — the host kernel-source environment used by
the regen does not match the SDK's BCM_KF Kconfig, so those symbols resolve away.
The build's own `syncconfig` then sees them as missing/NEW, prompts for each
non-interactively → **"Unexpected EOF"** → build fails.

**Rule: only ever edit `config_base.6a.6813` IN PLACE** — flip a line with sed:

```
sed:  '# CONFIG_X is not set'   ->   'CONFIG_X=y'
```

That is exactly what `scripts/configure-kernel.sh` does (with a `.orig` backup).
Never regenerate it.

---

## 3. New-symbol pinning gotcha (the subtle one)

Enabling a CONFIG that **exposes previously-hidden symbols** (because it opens a
sub-menu) makes the build's `syncconfig` prompt for every newly-VISIBLE symbol
that has no value yet → EOF → fail.

- Example: `CONFIG_FTRACE=y` opens the entire tracing menu (`KPROBE_EVENTS`,
  `FUNCTION_TRACER`, dozens more) → many new prompts.
- That is why the KPROBES work stayed KPROBES-only (a kprobe kernel module needs
  only `register_kprobe`, no tracefs).

**Fix: pin every newly-exposed symbol in `config_base`** (usually
`# CONFIG_X is not set`). Iterate: build → read the `(NEW)` prompt in the log →
add that symbol's default to your fragment → re-apply → rebuild. Repeat until no
new prompts.

For **KPROBES** the complete set is:
```
CONFIG_KPROBES=y
CONFIG_KALLSYMS_ALL=y
# CONFIG_KPROBES_SANITY_TEST is not set     <- newly exposed by KPROBES; must pin
```
(`CONFIG_OPTPROBES` is `def_bool` → auto-resolved, no pin needed.)
That is `config-fragments/kprobes.fragment`.

---

## 4. Full build

```bash
cd $FW && rtk ./build.sh
```
`build.sh` is an env+orchestration wrapper that ends with, inside `$SDKDIR`:
```
env -u LD_LIBRARY_PATH make FORCE=1 SHELL=/bin/bash \
    GTBE98_TC_ROOT=... GTBE98_ROOT=... LD_LIBRARY_PATH= gt-be98
```
- `FORCE=1` recompiles even when `.config` is unchanged.
- `SHELL=/bin/bash` — the SDK asserts `$BASH_VERSION`; Debian `/bin/sh` is dash.
- `env -u LD_LIBRARY_PATH` + `LD_LIBRARY_PATH=` — merlin must not use the
  crosstool `lib/`.
- **profile_saved_check guard:** if a profile file is newer than its
  `.last_profile` cookie, the guard fires; `FORCE=1` touches the cookie and
  exits 1 on the FIRST run. So just **re-run `build.sh` once** (build-kernel.sh
  retries automatically). You do NOT need to touch the profile for a config_base
  change.

---

## 5. Standalone kernel-only build (faster, fragile)

In `$KD`:
```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- \
     MODEL=GTBE98 BCM_KF=y LINUX_VER_STR=4.19.294 -j$(nproc) Image
```
Discovered-the-hard-way requirements:

- **PATH** must include the crosstools bin:
  `$FW/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1/bin`
  (cross prefix `aarch64-buildroot-linux-gnu-`).
- **`LINUX_VER_STR=4.19.294`** — Kconfig sources `Kconfig.bcm_kf.$(LINUX_VER_STR)`.
- **`MODEL=GTBE98`** — without it the top Makefile (~line 452)
  `KBUILD_CFLAGS += -D$(MODEL)` becomes a bare `-D` → *"macro names must be
  identifiers"*.
- **`BCM_KF=y`** — `Kconfig.bcmconfig` sources the BCM_KF symbol defs only
  `if "$(BCM_KF)" = "y"`; without it ~380 BCM_KF symbols (incl
  `BCM_SKB_CB_SIZE`) vanish → compile errors.
- For **out-of-tree modules** against this kernel you ALSO need:
  `BUILD_DIR=$SDKDIR KERNEL_DIR=$KD TOPDIR=$KD BRCMDRIVERS_DIR=$SDKDIR/bcmdrivers
  BRCMDRIVERS_DIR_RELATIVE=../../bcmdrivers SHARED_DIR=$SDKDIR/shared`
  (the `Makefile.brcm_pre` `-I` paths; `bcm_skbuff.h` needs `BUILD_DIR`).

A standalone `make Image` works without the module vars, but `BCM_KF=y` pulls
bcmdrivers into the kernel build which then needs more vars — so for a packaged
kernel image **the full `build.sh` is more reliable**. Use `image` mode only to
check that a config compiles.

---

## 6. Output + verifying the config landed

- Raw kernel image: `$KD/arch/arm64/boot/Image`
- Full build packages:
  - `$SDKDIR/targets/96813GW/GT-BE98_3006_102.6_0_nand_squashfs.pkgtb` (the
    flashable container; with KPROBES it was ~77.8 MB vs stock ~77.37 MB)
  - `bcm96813GW_uboot_linux.itb` (the bootfs FIT)
- Verify the configs compiled in:
  ```bash
  zcat $KD/kernel/config_data.gz | grep CONFIG_KPROBES     # =y
  grep register_kprobe $KD/System.map                      # symbol present
  ```
  `scripts/build-kernel.sh` runs these checks automatically (set `VERIFY_SYMS`).

---

## 7. Split + flash (device = `ssh -p 2222 admin@10.0.0.8`)

### Split
The `.pkgtb` is a FIT with two sub-images:
```bash
dumpimage -T flat_dt -p 0 -o bootfs.itb <pkgtb>   # kernel FIT (ATF+u-boot+kernel+DTB), ~13MB
dumpimage -T flat_dt -p 1 -o rootfs.img <pkgtb>   # rootfs squashfs, ~62MB
```
For a **kernel-only change, flash ONLY the bootfs**. (`scripts/split-pkgtb.sh`.)

### Transfer to device (binary-safe)
Device busybox has **no base64** and the `rtk` Bash hook rejects binary `cat`, so
use WRAPPED base64 (default 76-col wrap — NOT `base64 -w0`, device openssl chokes
on one huge line). Stage to `/tmp` (`/data` fills up):
```bash
base64 bootfs.itb | ssh -p 2222 admin@10.0.0.8 'openssl base64 -d > /tmp/bootfs.itb'
# pull FROM device:
ssh -p 2222 admin@10.0.0.8 'openssl base64 -e < file' | base64 -d > out
```

### The slot model
| | bootfs vol | rootfs vol | rootfs blk | trial IP | role |
|---|---|---|---|---|---|
| **slot1** | `ubi0_3` (`bootfs1`, static) | `ubi0_4` (`rootfs1`) | `/dev/ubiblock0_4` | **10.0.0.95** | the **trial** slot we flash |
| **slot2** | `ubi0_5` (`bootfs2`) | `ubi0_6` (`rootfs2`) | `/dev/ubiblock0_6` | **10.0.0.8** | committed stock fallback |

(Numbers observed on this unit — `scripts/flash-slot1.sh` re-confirms live with
`ubinfo` and refuses to touch the slot2 range.)

**Flash slot1 ONLY, NEVER slot2.** `bcm_bootstate` is authoritative for which
slot is committed. Currently slot2 is committed (safe fallback); slot1 is the
trial. If the new bootfs is bigger than the vol, grow it:
```bash
ubirmvol /dev/ubi0 -N bootfs1
ubimkvol /dev/ubi0 -N bootfs1 -s <bytes> -t static -n 3
ubiupdatevol /dev/ubi0_3 /tmp/bootfs.itb
```
Then arm a one-time slot1 boot and reboot:
```bash
bcm_bootstate 6     # boot slot1 ONCE; does NOT change commit flags
reboot
```

### Safety / recovery
- A fully-booting firmware **AUTO-COMMITS its slot** — `bcm_bootstate 6` alone is
  NOT revert-safe once slot1 boots clean. Layer the **deadman watchdog**: it
  reverts to slot2 in ~4 min if slot1 wedges. Slot1's minimal rootfs does NOT
  auto-load wifi/nvram.
- After a good slot1 boot, to KEEP it: on the device
  `touch /tmp/deadman-disarm; /bin/wdtctl stop`.
- Force-revert any time: on the device `bcm_bootstate 7 && reboot` → stock slot2.
- Device IP flips by slot: slot1 trial = 10.0.0.95, slot2 stock = 10.0.0.8. A
  poll seeing 10.0.0.8 right after `reboot` may be the pre-reboot slot2 still up
  — wait for link-down first.

> **Live flash/boot needs per-session user authorization.** Building on dev-build
> and operating on `config_base` copies is always fine; flashing a device is not.

---

## 8. Why a fragment, not menuconfig

`make menuconfig` in `$SDKDIR` edits the **profile**, not the kernel `.config`
(gendefconfig is off). The durable lever is `config_base` text. A *fragment* (a
file of `CONFIG_X=y` / `# CONFIG_X is not set` lines) applied in place is the
reproducible, reviewable, version-controllable way to express a kernel-config
delta — which is the whole point of this repo.
