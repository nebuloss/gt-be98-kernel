# gt-be98-kernel

Reproducible custom **kernel** builds for the **ASUS GT-BE98** (BCM6726/6813,
asuswrt-merlin SDK `src-rt-5.04behnd.4916`, profile `96813GW`, **Linux
4.19.294**), done the **standard kbuild way**: a tracked base *defconfig* +
*config fragments* + `make olddefconfig`, then the SDK's `build.sh` to package,
then split + flash.

This repo is SCRIPTS + DOCS + a base defconfig + config fragments that operate
on the merlin SDK **in place**; it does **not** vendor a copy of the SDK.

> **Read [`docs/build-internals.md`](docs/build-internals.md)** for the full
> story — including the three old "rules" (no `olddefconfig`, hand-pin new
> symbols, `.config` is clobbered each build) that were investigated and
> **disproven**. They were wrong-environment artifacts; in the right env this
> kernel configures like any normal kernel.

---

## Topology (CRITICAL)

- **dev-code** (10.0.50.20): source + git ONLY. Do **NOT** build here.
- **dev-build** (10.0.50.21): all compiling, over SSH (`ssh guillaume@10.0.50.21`),
  wrapped in `rtk`.
- SDK lives on **both** at
  `~/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916`
  (`SDKDIR`); kernel tree `$SDKDIR/kernel/linux-4.19` (`KD`).
- Device: `ssh -p 2222 admin@10.0.0.8` (committed slot2). Flash slot1 ONLY.

Workflow: edit/add a fragment here → commit/push → on dev-build pull →
`configure-kernel.sh` (regenerates `$KD/.config` from base + fragments) →
`build-kernel.sh` → `split-pkgtb.sh` → `flash-slot1.sh`.

---

## The model

Just like a normal kernel: **configure → `make` → package → flash.**

```
configs/gtbe98_defconfig   --make gtbe98_defconfig-->  .config
  + config-fragments/*     --merge_config.sh-------->  .config
                           --make olddefconfig------>  .config   (ready)
  build.sh (make gt-be98)  ----------------------->   .pkgtb
  split-pkgtb.sh           ----------------------->   bootfs.itb + rootfs.img
  flash-slot1.sh           ----------------------->   slot1 (trial)
```

- **Durable config source** = `configs/gtbe98_defconfig` in THIS repo (a minimal
  `savedefconfig`, version-controlled). The old in-place editing of the SDK's
  `config_base.6a.6813` is gone.
- **Feature deltas** = standard kbuild **fragments** in `config-fragments/`.
- `make olddefconfig` (with `BCM_KF=y`) is **safe and required** — it preserves
  all `BCM_KF` symbols and resolves newly-exposed symbols to defaults
  non-interactively (no pinning, no "Unexpected EOF").

The four env knobs that make this work (host tools first on `PATH`, no
`LD_LIBRARY_PATH`, `BCM_KF=y`, `LINUX_VER_STR=4.19.294`/`MODEL=GTBE98`) are
encoded once in [`scripts/kernel-env.sh`](scripts/kernel-env.sh).

> **Why the vendor tree, not mainline kernel.org?** This SDK's 4.19 is heavily
> patched (`CONFIG_BCM_KF_*`, the closed `dhd`/`wl` WiFi stack, FIT/UBI flash
> packaging). Building from official sources + blobs is a much larger effort —
> see `docs/build-internals.md` §6. This repo standardizes the *config + build*
> within the working vendor tree first.

---

## Quickstart (KPROBES example)

```bash
# --- on dev-build (10.0.50.21) ---
ssh guillaume@10.0.50.21
cd ~/be98/gt-be98-kernel && git pull

# 1. Regenerate .config from the base defconfig + the fragment(s) you want.
./scripts/configure-kernel.sh config-fragments/kprobes.fragment

# 2. Build the KERNEL (Image + .ko modules; no userspace) and verify symbols.
#    For a full flashable .pkgtb instead, use `./scripts/build-kernel.sh full`
#    (needs scripts/sync-prebuilts.sh first — see docs §7).
VERIFY_SYMS="CONFIG_KPROBES CONFIG_KALLSYMS_ALL register_kprobe" ./scripts/build-kernel.sh kernel

# 3. Split the .pkgtb into bootfs.itb + rootfs.img.
./scripts/split-pkgtb.sh

# 4. Flash SLOT1 ONLY (kernel-only change -> bootfs alone), arm one-time boot, reboot.
#    (REQUIRES per-session user authorization to touch the device)
./scripts/flash-slot1.sh /path/to/targets/96813GW/bootfs.itb
```

From dev-code you can dispatch the build to dev-build:
`./scripts/build-kernel.sh --remote full`.

Interactive: `./scripts/configure-kernel.sh -m config-fragments/kprobes.fragment`
seeds the config then opens `menuconfig`; persist changes with
`./scripts/save-defconfig.sh`.

---

## Repo layout

```
README.md                      this file
docs/build-internals.md        full config-chain + env knowledge (READ for the why)
configs/
  gtbe98_defconfig             tracked minimal base defconfig (STOCK; savedefconfig)
config-fragments/
  kprobes.fragment             example feature delta (standard kbuild fragment)
patches/
  bcm-kf-mods.patch            edits to UPSTREAM 4.19.294 files (362 files, +11.8k/-186)
  deletions.list               upstream files the vendor removes (234)
  README.md                    the official-source + delta model
overlay/                       wholly-new vendor source files (722, ~10M; browsable)
scripts/
  kernel-env.sh                sourced env helper (PATH/LD_LIBRARY_PATH/BCM_KF/...)
  configure-kernel.sh          base defconfig + fragments + olddefconfig -> $KD/.config
  save-defconfig.sh            $KD/.config -> configs/gtbe98_defconfig (savedefconfig)
  fetch-mainline.sh            pristine kernel.org 4.19.294 + delta -> reconstructed source
  sync-prebuilts.sh            restore closed bcmdrivers prebuilt .o (from a ref SDK) for a full build
  build-kernel.sh              build on dev-build via rtk (full | image), verify, print pkgtb
  split-pkgtb.sh               dumpimage split of the .pkgtb into bootfs.itb + rootfs.img
  flash-slot1.sh               transfer + flash SLOT1 only (safety-guarded), bcm_bootstate 6 + reboot
```

## Official kernel.org source + reviewable delta

The kernel is **official Linux 4.19.294 + a reviewable delta** (no binary blobs
in the kernel tree — verified). Reconstruct it from the pristine kernel.org
tarball:
```bash
scripts/fetch-mainline.sh            # -> build/linux-4.19.294 (official + delta)
VERIFY=1 scripts/fetch-mainline.sh   # diff the result vs the SDK tree -> 0 source diffs
```
The delta is split into `patches/bcm-kf-mods.patch` (edits to upstream files, the
auditable `BCM_KF` footprint), `overlay/` (added vendor source), and
`patches/deletions.list`. See [`patches/README.md`](patches/README.md) and
`docs/build-internals.md §6`.

Scripts parameterize SDK/device paths via env vars with sensible defaults
(`FW`, `SDKDIR`, `KD`, `TARGET`, `DEVICE`, `DEVPORT`, ...). No secrets hardcoded.

---

## Adding a new config

1. Write a fragment in `config-fragments/`, e.g. `myfeature.fragment`:
   ```
   CONFIG_FOO=y
   # CONFIG_FOO_DEBUG is not set
   ```
2. `./scripts/configure-kernel.sh config-fragments/myfeature.fragment`
   (combine multiple: pass several fragment paths.)
3. `./scripts/build-kernel.sh`

`olddefconfig` auto-resolves any symbols your change newly exposes — you do
**not** have to pin them by hand. To bake a setting into the base instead of a
fragment, tune via `configure-kernel.sh -m` then `save-defconfig.sh`.

---

## Safety (flashing)

`flash-slot1.sh` enforces the golden rules: refuses unless `bcm_bootstate`
confirms slot2 is committed, refuses if booted on slot1, refuses any slot2-range
volume, transfers binary-safe via `base64 | openssl base64 -d`, grows the volume
if needed, then `bcm_bootstate 6` (boot slot1 ONCE) + reboot. A fully-booting
firmware auto-commits its slot, so layer the deadman watchdog for risky boots
(reverts to slot2 in ~4 min). Recover any time: on the device
`bcm_bootstate 7 && reboot`.

**Live flash/boot requires per-session user authorization.** Building and
regenerating `.config` on dev-build is always fine.

---

## Validation status

- The standard config pipeline was validated end-to-end against the live tree on
  dev-build (configs only, live `.config` untouched during the experiments):
  - `olddefconfig` with `BCM_KF=y` preserves **68/68** `BCM_KF` and **195/195**
    `BCM_*` symbols, **0** `(NEW)` prompts.
  - `savedefconfig` round-trips the known-good config **exactly** (0 lost/added).
  - **stock base + `kprobes.fragment` + olddefconfig == the hand-built KPROBES
    config, exactly.**
- A full `build.sh` end-to-end build with this pipeline: see the commit/PR notes
  for the latest run on dev-build.

---

## GitHub remote

Intended remote: `git@github.com:nebuloss/gt-be98-kernel.git`.
```bash
gh repo create nebuloss/gt-be98-kernel --private --source=. --remote=origin --push
# or, if created via web UI:
git remote add origin git@github.com:nebuloss/gt-be98-kernel.git
git push -u origin main
```
