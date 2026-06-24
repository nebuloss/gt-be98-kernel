# GT-BE98 custom kernel — build internals

How to configure and build a custom kernel for the ASUS GT-BE98 (BCM6726/6813,
asuswrt-merlin SDK `src-rt-5.04behnd.4916`, profile `96813GW`, Linux
**4.19.294**) **the standard kbuild way**: a tracked base *defconfig* + *config
fragments* + `make olddefconfig`, then the SDK's `build.sh` to package.

> Topology: **dev-code** (10.0.50.20) = source + git ONLY, never build.
> **dev-build** (10.0.50.21) = all compiling, over SSH, wrapped in `rtk`. The
> merlin SDK lives on **both** at
> `~/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916`.

Path shorthand:
```
FW      = ~/be98/gt-be98-firmware
SDKDIR  = $FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
KD      = $SDKDIR/kernel/linux-4.19
TARGET  = 96813GW
```

---

## 0. History — three "rules" that turned out to be environment bugs

An earlier version of this repo edited `$KD/config_base.6a.6813` in place with
`sed` and forbade `olddefconfig`, built on three claims. **All three were
investigated empirically (2026-06-24) and disproven** — they were artifacts of
the *wrong environment*, not real kernel constraints. The evidence:

| Old claim | Finding |
|---|---|
| "`olddefconfig` strips ~64 `CONFIG_BCM_KF_*` symbols — never regen." | With **`BCM_KF=y LINUX_VER_STR=4.19.294 MODEL=GTBE98`** and host tools first on `PATH`, `olddefconfig` preserved **68→68** `BCM_KF` and **195→195** `BCM_*` symbols, 0 lost. The stripping was the `BCM_KF`-*undefined* path: `build/pre_kernelbuild.mk`'s `kernel_cfg_rm_bcm_kf` literally `sed`-deletes `CONFIG_BCM_*=[my]` and only runs when `BCM_KF` is **not** defined. |
| "Enabling a sub-menu symbol → `(NEW)` prompt → 'Unexpected EOF' — pin every exposed symbol by hand." | That is a **`syncconfig`/`oldconfig`** (interactive) failure. **`olddefconfig` resolves newly-exposed symbols to their defaults non-interactively** — merging `kprobes.fragment` (which exposes `KPROBES_SANITY_TEST`) produced **0 prompts**. No manual pinning needed. |
| "`.config` is re-copied from `config_base → config_gt-be98 → config_current → .config` every build, so editing `.config` is futile." | **No makefile references `config_base`, `config_gt-be98`, or `config_current`.** The only `cp … .config` lines in `pre_kernelbuild.mk` are **commented out**. The build just runs the kernel's own `make olddefconfig` on the existing `.config`. That "chain" was a *manual* procedure, not a build step; `.config` is **not** clobbered. |

The `config_base.6a.6813` / `config_gt-be98` / `config_current` files in `$KD`
are leftover scratch/staging artifacts of that manual process — the merlin build
does not consume them. **This repo no longer touches them.** The durable,
version-controlled config source is now `configs/gtbe98_defconfig` in THIS repo.

---

## 1. The environment that makes the kernel behave like a normal kernel

Encoded once in [`scripts/kernel-env.sh`](../scripts/kernel-env.sh); every script
sources it. Four things, all *environment*:

1. **Host tools first on `PATH`** (`/usr/bin:/bin:$TCDIR:$PATH`). The aarch64
   crosstools `*/usr/bin` ships a `bison` that needs `libreadline.so.6` (absent
   on modern distros); if it shadows the host `bison`, kconfig won't even build
   (`bison: error while loading shared libraries: libreadline.so.6`). The SDK's
   own `tools/env.sh` warns about exactly this.
2. **`LD_LIBRARY_PATH` unset.** Crosstools `lib/` breaks the host `gcc`/`cc1`
   (`mpfr_asinpi`). `build.sh` clears it too.
3. **`BCM_KF=y`.** `$KD/Kconfig.bcmconfig` sources `../bcmkernel/Kconfig.bcm_kf*`
   **only `if "$(BCM_KF)" = "y"`**. Those files define the ~68 `CONFIG_BCM_KF_*`
   and ~190 `CONFIG_BCM_*` symbols. Run config without `BCM_KF=y` and they are
   unknown → dropped. With it, they round-trip cleanly.
4. **`LINUX_VER_STR=4.19.294`** (Kconfig sources `Kconfig.bcm_kf.$(LINUX_VER_STR)`)
   and **`MODEL=GTBE98`** (the top Makefile does `-D$(MODEL)`; a bare `-D`
   errors "macro names must be identifiers"). `ARCH=arm64`,
   `CROSS_COMPILE=aarch64-buildroot-linux-gnu-` as usual.

`kernel-env.sh` exports these and provides `kmake` (= `make -C $KD` with the
flags applied). Use `kmake olddefconfig`, `kmake menuconfig`, `kmake savedefconfig`,
`kmake -j"$(nproc)" Image`, etc.

> kconfig 4.19 quirk: when pointing `KCONFIG_CONFIG` at a scratch file, keep it
> **relative to `$KD`**. An absolute `/tmp/...` path makes `conf` fail with
> "Error during writing of the configuration" (it writes its temp/backup
> relative to the cwd). The scripts always operate on `$KD/.config`, so this
> only bites ad-hoc experiments.

---

## 2. The config workflow (standard kbuild)

```
configs/gtbe98_defconfig        # tracked, minimal (savedefconfig) base — STOCK
        │  make gtbe98_defconfig
        ▼
   $KD/.config                  # expanded
        │  merge_config.sh -m  config-fragments/*.fragment
        ▼
   $KD/.config (+ deltas)
        │  make olddefconfig     # resolve all (incl. newly-exposed) to defaults
        ▼
   $KD/.config (final, ready to build)
```

[`scripts/configure-kernel.sh`](../scripts/configure-kernel.sh) does all three
steps:

```bash
# on dev-build
cd ~/be98/gt-be98-kernel && git pull
scripts/configure-kernel.sh config-fragments/kprobes.fragment
```

It installs `gtbe98_defconfig` into `arch/arm64/configs/` (so the standard
`make <name>_defconfig` target works), seeds `.config`, merges fragments with
the kernel's own `scripts/kconfig/merge_config.sh`, and runs `olddefconfig`. It
reports the resulting `BCM_KF` count (expect ~68) as a preserved-symbols check.

**A config fragment** is a plain file of `CONFIG_X=y` / `# CONFIG_X is not set`
lines — the exact format `merge_config.sh` consumes. See
`config-fragments/kprobes.fragment`. To add a feature: drop a new fragment in
`config-fragments/`, pass it to `configure-kernel.sh`, build.

**Interactive tuning:** `scripts/configure-kernel.sh -m [fragments...]` seeds the
config then opens `make menuconfig`. To persist what you changed back into the
tracked base, run [`scripts/save-defconfig.sh`](../scripts/save-defconfig.sh)
(`make savedefconfig` → `configs/gtbe98_defconfig`), copy it to dev-code, commit.

### Why a defconfig + fragments (not in-place edits)

`make menuconfig` at the **SDK top level** edits the profile, not the kernel
`.config` (gendefconfig is commented out in `pre_kernelbuild.mk`, so the profile
is inert for the kernel config). The durable lever is the kernel `.config`, and
the reproducible, reviewable, version-controlled way to express it is a base
defconfig plus fragments — regenerated deterministically each time.

### savedefconfig fidelity (verified)

`savedefconfig` emits only symbols that differ from their Kconfig default (647
lines vs ~3400 set lines). Re-expanding it (`make gtbe98_defconfig` +
`olddefconfig`, in the `BCM_KF=y` env) reproduced the known-good config
**exactly**: BCM_KF 68, BCM_* 196, 0 symbols lost/added. And **stock base +
`kprobes.fragment`** reproduced the hand-built KPROBES config exactly. So the
minimal defconfig is a faithful base as long as the SDK Kconfig is unchanged.

---

## 3. Build — kernel-space vs user-space

The merlin build has a **phase boundary** that matches the right separation of
concerns, and `build-kernel.sh` exposes it:

| Phase / mode | Builds | Belongs to |
|---|---|---|
| **`kernel`** (default) = SDK `recipe_kernel` | kernel `Image` + all `.ko` modules (incl. `=m` bcmdrivers); installs to `…/fs/lib/modules/4.19.294/` | **the kernel** |
| `userspace` (NOT run by `kernel` mode) | libnl, router daemons, the rootfs userland | the **rootfs** / firmware |
| **`full`** = `build.sh` (`make gt-be98`) | both phases + packaging → `.pkgtb` | firmware integration |

```bash
scripts/build-kernel.sh            # kernel + modules (recipe_kernel) — NO userspace
scripts/build-kernel.sh kernel
scripts/build-kernel.sh full       # whole firmware -> .pkgtb
scripts/build-kernel.sh --remote kernel   # from dev-code, dispatch to dev-build
```

> **The vendor kernel is NOT standalone-buildable.** `BCM_KF=y` adds `brcmdrivers-y`
> to the *kernel's own* build, so building the `Image` compiles bcmdrivers in
> (the 68 `BCM_KF_*` kernel patches + 94 `=y` platform/accel drivers are intrinsic;
> only the 34 `=m` are loadable modules). A bare `make Image` therefore needs the
> full SDK env and unravels — so `kernel` mode reuses the firmware's build env
> (`tools/env.sh`) and drives `recipe_kernel`, which is the reliable kernel build.
> `image` mode (bare `make Image`) is kept only as a fragile compile-check.

The `recipe_kernel` phase produces the kernel + modules and **never enters the
`userspace` phase** (verified: `USERSPACE STARTED` count 0) — so userspace-tool
build issues (e.g. the `libnl` relink) belong to the rootfs build, not here.

`build.sh` ends with, inside `$SDKDIR`:
```
env -u LD_LIBRARY_PATH make FORCE=1 SHELL=/bin/bash GTBE98_*_ROOT=... LD_LIBRARY_PATH= gt-be98
```
- `FORCE=1` recompiles even when `.config` is unchanged.
- `SHELL=/bin/bash` — the SDK asserts `$BASH_VERSION`; Debian `/bin/sh` is dash.
- `env -u LD_LIBRARY_PATH` + `LD_LIBRARY_PATH=` — host tools must not use crosstool `lib/`.
- **profile_saved_check guard:** on the FIRST `FORCE=1` run it may touch
  `.last_profile` and exit 1; just re-run (build-kernel.sh retries once).

The build runs the kernel's own `make olddefconfig` (via `build/Bcmkernel.mk`)
against the `.config` you produced — it does not regenerate it from anything
else. For a **packaged, flashable** image use `full`; `image` only builds the
raw `Image` and is for checking that a config compiles.

### Standalone kernel build (what `image` runs)
```bash
kmake -j"$(nproc)" Image          # == make -C $KD ARCH=arm64 CROSS_COMPILE=... MODEL=GTBE98 BCM_KF=y LINUX_VER_STR=4.19.294 Image
```
`BCM_KF=y` pulls bcmdrivers into the kernel build, which for some targets needs
more module vars (`BUILD_DIR`, `KERNEL_DIR`, `BRCMDRIVERS_DIR`, …). For a
packaged kernel the full `build.sh` is more reliable; use `image` for quick
compile checks.

---

## 4. Output + verifying the config landed

- Raw kernel image: `$KD/arch/arm64/boot/Image`
- Packaged: `$SDKDIR/targets/96813GW/GT-BE98_*_nand_squashfs.pkgtb` (flashable
  container) and `bcm96813GW_uboot_linux.itb` (bootfs FIT).
- Verify configs compiled in (build-kernel.sh does this via `VERIFY_SYMS`):
  ```bash
  zcat $KD/kernel/config_data.gz | grep CONFIG_KPROBES   # =y
  grep register_kprobe $KD/System.map                    # symbol present
  ```

---

## 5. Split + flash (device = `ssh -p 2222 admin@10.0.0.8`)

Unchanged from the packaging story; the kernel-config rework does not touch it.

### Split
The `.pkgtb` is a FIT with two sub-images:
```bash
dumpimage -T flat_dt -p 0 -o bootfs.itb <pkgtb>   # kernel FIT (ATF+u-boot+kernel+DTB), ~13MB
dumpimage -T flat_dt -p 1 -o rootfs.img <pkgtb>   # rootfs squashfs, ~62MB
```
For a **kernel-only change, flash ONLY the bootfs** (`scripts/split-pkgtb.sh`).

### Transfer (binary-safe)
Device busybox has no base64 and the `rtk` hook rejects binary `cat`; use wrapped
base64 (default 76-col, NOT `-w0`). Stage to `/tmp` (`/data` fills up):
```bash
base64 bootfs.itb | ssh -p 2222 admin@10.0.0.8 'openssl base64 -d > /tmp/bootfs.itb'
```

### Slot model
| | bootfs vol | rootfs vol | rootfs blk | trial IP | role |
|---|---|---|---|---|---|
| **slot1** | `ubi0_3` (`bootfs1`, static) | `ubi0_4` (`rootfs1`) | `/dev/ubiblock0_4` | **10.0.0.95** | the **trial** slot we flash |
| **slot2** | `ubi0_5` (`bootfs2`) | `ubi0_6` (`rootfs2`) | `/dev/ubiblock0_6` | **10.0.0.8** | committed stock fallback |

**Flash slot1 ONLY, NEVER slot2.** `scripts/flash-slot1.sh` re-confirms volumes
live with `ubinfo`, refuses unless `bcm_bootstate` says slot2 is committed,
refuses if booted on slot1, grows the volume if the image is larger, then
`bcm_bootstate 6` (boot slot1 ONCE) + reboot.

### Safety / recovery
- A fully-booting firmware **auto-commits its slot** — `bcm_bootstate 6` alone is
  not revert-safe once slot1 boots clean. Layer the deadman watchdog (reverts to
  slot2 in ~4 min). After a good slot1 boot, to keep it: on the device
  `touch /tmp/deadman-disarm; /bin/wdtctl stop`.
- Force-revert any time: on the device `bcm_bootstate 7 && reboot` → stock slot2.

> **Live flash/boot needs per-session user authorization.** Building on dev-build
> and regenerating `.config` from the repo base is always fine; flashing is not.

---

## 6. "Official kernel.org sources + proprietary blobs" — feasibility

A natural goal: build from **mainline/official Linux 4.19.294** plus only the
closed **blobs**, instead of Broadcom's patched SDK tree. In theory yes; in
practice this is a large project for a BCM6813 "behnd" router, because the parts
that make it a *router* are out-of-tree **source patches**, not just loadable
blobs:

- **`CONFIG_BCM_KF_*`** ("Broadcom Kernel Feature") — ~68 symbols gating
  thousands of lines of in-tree patches across arch/mm/net/drivers. These are
  not modules you load; they modify core kernel code.
- **`bcmdrivers/` + `bcmkernel/`** — the SoC platform (boot, clocks, memory
  map), the packet accelerator (Runner/RDP/pktflow/Archer/FAP), Ethernet/switch,
  flash/UBI, etc. Mostly source (some objects). Mainline has **no** support for
  these "behnd" SoCs.
- **WiFi (`dhd`/`wl`)** — the closed blob. It is compiled/linked against the
  **vendor kernel's ABI** and expects the BCM_KF networking hooks (`BCM_KF_BLOG`,
  `BCM_KF_WL`, the pktflow path). Dropping it onto a clean kernel.org tree won't
  give working WiFi without that surrounding patched infrastructure.

So a kernel.org-based build that keeps **WiFi + hardware routing** working is not
currently feasible without effectively reconstructing Broadcom's out-of-tree
tree. The realistic spectrum:

1. **This repo today** — vendor tree, standard config/build workflow. Works.
2. **Port BCM_KF onto clean 4.19.294** — extract the vendor delta as patches and
   re-apply to kernel.org 4.19.294. Large, ongoing maintenance; still needs the
   closed bcmdrivers/wl for a useful router.
3. **OpenWrt-style** — only partial upstream support exists for some BCM63xx;
   BE-series WiFi 7 (BCM6813 + wl/dhd) is not openly supported.

### Measured patch surface + the implemented "official source" path

This was measured (diff of `$KD` vs pristine kernel.org **4.19.294**) and the
result is encouraging: edits to **upstream** files are modest and surgical —
**362 files, +11,832 / −186 lines**, almost all `CONFIG_BCM_KF_*`-guarded. The
bulk (~10M, 722 files) is **wholly-new vendor source** (the `mach-bcm963xx`
platform, `Kconfig.bcmconfig`, backported `net/wireguard` + `net/mptcp`, the bcm
IIO tree, …). Crucially, **0 binary files differ** from mainline — every binary
in the SDK kernel tree is build output. **There are no proprietary blobs in the
kernel** (the `wl`/`dhd` blobs are in `bcmdrivers/`, outside the kernel tree).

So the kernel really is "official kernel.org source + a reviewable delta," and
that path is **implemented** (option 1):

```
patches/bcm-kf-mods.patch   edits to upstream files (the auditable BCM_KF delta)
overlay/                    the added vendor source files (browsable)
patches/deletions.list      upstream files the vendor removes
scripts/fetch-mainline.sh   pristine 4.19.294 + mods + overlay - deletions  ->  $KD-equivalent
```

`fetch-mainline.sh` downloads pristine 4.19.294 (sha256-pinned), applies the
delta, and (with `VERIFY=1`) diffs the result against the SDK tree — **0 source
differences**. See [`patches/README.md`](../patches/README.md).

**What this gets you / what it doesn't.** It makes the kernel *source* provably
official-base + auditable-patch (transparency, reviewable BCM_KF footprint, a
clean base to rebase onto a newer 4.19.x). It does **not** make a near-mainline
kernel: the ~10M of added vendor source is required (SoC platform + the
networking glue the closed `wl`/`dhd` bind to), and a *flashable firmware* still
needs the out-of-tree `bcmdrivers/` + toolchain + those blobs, plus the SDK
packaging (see §7 for the prebuilt-blob prerequisite).

---

## 7. Full firmware build: the missing closed prebuilt `.o`

A full `build.sh` (`make gt-be98` → `.pkgtb`) needs closed Broadcom prebuilt
objects that **gnuton's SDK does not ship** and that have **no source**:
`bcm_bpm.o`, `cmdlist.o`, `bcmvlan.o`, `pktflow.o` (and `rdpa_cmd.o`,
`rdpa_gpl_ext.o`, `rdpa_mw.o`, `unimac_drv_impl1.o`, …). Without them the build
dies at e.g. `cp: cannot stat '.../bpm/bcm96813/bcm_bpm.o'`. They are **not**
recoverable from git (untracked) and have no in-tree donor for BCM6813.

**They are available in a sibling RMerl checkout of the same SDK version**
(`~/re-sdk/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916`) and are
**ABI-compatible** with the gnuton tree (same `src-rt-5.04behnd.4916`, kernel
4.19.294, chip 6813, aarch64). [`scripts/sync-prebuilts.sh`](../scripts/sync-prebuilts.sh)
copies every prebuilt `.o` the reference SDK has that ours lacks, **only where no
same-name `.c` exists** (never shadowing open-source files the build compiles).

Second gotcha: `prune-vendor.sh` leaves **stale libtool state** in userspace —
empty `.libs/` dirs with surviving `.lo`/`.la` — so the build skips recompiling
then fails relinking (first hit: `libnl`, `genl/.libs/*.o: No such file`).
`sync-prebuilts.sh --clean-libtool` clears those so they rebuild from the intact
`.c`.

End-to-end recipe that produced a verified pkgtb (2026-06-24):
```bash
scripts/sync-prebuilts.sh --clean-libtool        # restore closed blobs + fix libtool
scripts/configure-kernel.sh config-fragments/kprobes.fragment
scripts/build-kernel.sh full                     # -> GT-BE98_*.pkgtb, verify-artifact OK
```
Result: `register_kprobe` in `System.map`, `CONFIG_KPROBES=y` in the kernel's
embedded `config_data.gz`, all `verify-artifact` checks passing.
