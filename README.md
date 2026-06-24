# gt-be98-kernel

Reproducible custom **kernel** builds for the **ASUS GT-BE98** (BCM6726/6813,
asuswrt-merlin SDK `src-rt-5.04behnd.4916`, profile `96813GW`, **Linux
4.19.294**).

This repo encapsulates the hard-won, reverse-engineered build knowledge so a
custom kernel CONFIG can be added **easily and reproducibly** — replacing the
ad-hoc, error-prone process figured out by hand. It is SCRIPTS + DOCS + config
fragments that operate on the merlin SDK **in place**; it does **not** vendor a
copy of the SDK.

> **Read [`docs/build-internals.md`](docs/build-internals.md) first.** It is the
> full explanation of the merlin config chain and every gotcha. The scripts just
> encode it.

---

## Topology (CRITICAL)

- **dev-code** (10.0.50.20): source + git ONLY. Do **NOT** build here.
- **dev-build** (10.0.50.21): all compiling, over SSH (`ssh guillaume@10.0.50.21`),
  wrapped in `rtk` to filter build spam.
- The merlin SDK lives on **both** machines at:
  `~/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916`
  (`SDKDIR`). The kernel tree is `$SDKDIR/kernel/linux-4.19` (`KD`).
- Device: `ssh -p 2222 admin@10.0.0.8` (committed slot2). Flash slot1 ONLY.

Workflow: edit a config fragment here → commit/push → on dev-build pull, run
`configure-kernel.sh` (edits `config_base` in place) → `build-kernel.sh` →
`split-pkgtb.sh` → `flash-slot1.sh`.

---

## The one thing to know

The kernel `.config` is re-copied from a base file **every build**, so editing
`.config` / `defconfig` / the profile is futile. **The only durable config
source is `$KD/config_base.6a.6813`.** Edit it IN PLACE (never `olddefconfig` it).
A *fragment* expresses your config delta; `configure-kernel.sh` applies it. See
the internals doc for the why.

---

## Quickstart (KPROBES example)

```bash
# --- on dev-build (10.0.50.21) ---
ssh guillaume@10.0.50.21
cd ~/be98/gt-be98-kernel && git pull        # this repo, checked out on dev-build

# 1. Apply the config fragment to the DURABLE config_base (in place, with .orig backup)
./scripts/configure-kernel.sh config-fragments/kprobes.fragment

# 2. Build (full build.sh -> .pkgtb) and verify the symbols landed
VERIFY_SYMS="CONFIG_KPROBES CONFIG_KALLSYMS_ALL register_kprobe" ./scripts/build-kernel.sh

# 3. Split the .pkgtb into bootfs.itb + rootfs.img
./scripts/split-pkgtb.sh        # auto-finds the GT-BE98 pkgtb

# 4. Flash SLOT1 ONLY (kernel-only change -> bootfs alone), arm one-time boot, reboot
#    (REQUIRES per-session user authorization to touch the device)
./scripts/flash-slot1.sh /path/to/targets/96813GW/bootfs.itb
```

From dev-code you can dispatch the build to dev-build:
`./scripts/build-kernel.sh --remote full`.

---

## Repo layout

```
README.md                      this file
docs/build-internals.md        the full config-chain + gotchas knowledge (READ FIRST)
config-fragments/
  kprobes.fragment             verified KPROBES delta (KPROBES, KALLSYMS_ALL, SANITY_TEST pinned)
scripts/
  configure-kernel.sh          apply a fragment to config_base.6a.6813 IN PLACE (idempotent, .orig backup, --restore)
  build-kernel.sh              build on dev-build via rtk (full | image), verify config_data.gz/System.map, print pkgtb
  split-pkgtb.sh               dumpimage split of the .pkgtb into bootfs.itb + rootfs.img
  flash-slot1.sh               transfer + flash SLOT1 only (safety-guarded), bcm_bootstate 6 + reboot
```

All scripts parameterize SDK/device paths via env vars with sensible defaults
(`SDKDIR`, `KD`, `FW`, `TARGET`, `DEVICE`, `DEVPORT`, ...). No secrets are
hardcoded.

---

## Adding a new config

1. Write a fragment in `config-fragments/`, e.g. `myfeature.fragment`:
   ```
   CONFIG_FOO=y
   # CONFIG_FOO_DEBUG is not set
   ```
2. `./scripts/configure-kernel.sh config-fragments/myfeature.fragment`
3. `./scripts/build-kernel.sh`
4. If the build log shows a `(NEW)` prompt → "Unexpected EOF", you enabled a
   symbol that exposed sub-symbols. Add each newly-visible symbol's default to
   your fragment (usually `# CONFIG_X is not set`), re-apply, rebuild. Iterate.
   See internals doc §3.

To revert `config_base` to pristine: `./scripts/configure-kernel.sh --restore`.

---

## Safety (flashing)

`flash-slot1.sh` enforces the golden rules: it refuses unless `bcm_bootstate`
confirms **slot2 is committed** (the fallback), refuses if the device is booted
on slot1, refuses any volume in the slot2 range, transfers binary-safe via
`base64 | openssl base64 -d`, grows the volume if the image is larger, then
`bcm_bootstate 6` (boot slot1 ONCE) + reboot. A fully-booting firmware
auto-commits its slot, so layer the deadman watchdog for risky boots (reverts to
slot2 in ~4 min). Recover any time: on the device `bcm_bootstate 7 && reboot`.

**Live flash/boot requires per-session user authorization.** Building and
applying fragments on copies is always fine.

---

## Validation status

- `configure-kernel.sh` was validated against a COPY of the live
  `config_base.6a.6813` applying `kprobes.fragment` (correct in-place edits +
  idempotency + `--restore`). The live `config_base` on dev-build was **not**
  disturbed (WiFi work is mid-flight).
- All scripts pass `bash -n` syntax checks.
- **A full kernel build and a device flash were NOT run end-to-end by the
  author of this repo** — the build/flash recipes are transcribed from a verified
  prior session (see `docs/build-internals.md`) but should be exercised once on
  dev-build/device before relying on them blindly.

---

## GitHub remote

Intended remote: `git@github.com:nebuloss/gt-be98-kernel.git`.
As of repo creation that GitHub repo **did not exist yet** (`git ls-remote`
returned "Repository not found"), so nothing was pushed. To create + push:

```bash
gh repo create nebuloss/gt-be98-kernel --private --source=. --remote=origin --push
# or, if the repo is created via the web UI:
git remote add origin git@github.com:nebuloss/gt-be98-kernel.git
git push -u origin main
```
