#!/usr/bin/env bash
# configure-kernel.sh — apply a CONFIG fragment to the merlin kernel's DURABLE
# config source, config_base.6a.6813, IN PLACE.
#
# This is the ONLY config file the merlin build does not overwrite. Editing
# .config / arch/arm64/defconfig / defconfig-bcm.template / the profile is
# futile (all are clobbered by `cp config_current .config`). See
# docs/build-internals.md for the full chain and why.
#
# A fragment is a file of lines, each either:
#     CONFIG_FOO=y           (or =m, =n, ="string", =123)
#     # CONFIG_FOO is not set
# Blank lines and lines starting with '#' that are NOT a "# CONFIG_X is not set"
# directive are treated as comments and ignored.
#
# For each fragment line we:
#   - if config_base already has a line for that symbol (set OR "is not set"),
#     replace it in place (sed);
#   - else append the fragment line to the end.
# Idempotent: re-running with the same fragment is a no-op.
#
# A timestamped .orig backup of config_base is made on first run (and a
# .configure-kernel.bak just before each edit) so you can always restore.
#
# Run this where config_base lives. By default that is dev-build's SDK, but it
# can run anywhere the file is reachable (set KD). It does NOT build.
#
# Usage:
#   scripts/configure-kernel.sh config-fragments/kprobes.fragment
#   KD=/path/to/kernel/linux-4.19 scripts/configure-kernel.sh my.fragment
#   scripts/configure-kernel.sh --restore        # restore from the .orig backup
#
# Env:
#   SDKDIR  default ~/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
#   KD      default $SDKDIR/kernel/linux-4.19
#   CONFIG_BASE  default $KD/config_base.6a.6813   (6813 = our BCM6813 chip;
#               there is also a config_base.6a.6764L for a DIFFERENT chip)
set -euo pipefail

SDKDIR="${SDKDIR:-$HOME/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"
KD="${KD:-$SDKDIR/kernel/linux-4.19}"
CONFIG_BASE="${CONFIG_BASE:-$KD/config_base.6a.6813}"

die() { echo "configure-kernel: ERROR: $*" >&2; exit 1; }
info() { echo "configure-kernel: $*"; }

[[ -f "$CONFIG_BASE" ]] || die "config_base not found: $CONFIG_BASE (set SDKDIR/KD/CONFIG_BASE)"

# --restore: put back the pristine .orig and exit.
if [[ "${1:-}" == "--restore" ]]; then
    [[ -f "$CONFIG_BASE.orig" ]] || die "no $CONFIG_BASE.orig to restore from"
    cp -f "$CONFIG_BASE.orig" "$CONFIG_BASE"
    info "restored $CONFIG_BASE from .orig"
    exit 0
fi

FRAG="${1:-}"
[[ -n "$FRAG" ]] || die "usage: $0 <fragment-file> | --restore"
[[ -f "$FRAG" ]] || die "fragment not found: $FRAG"

# One-time pristine backup.
if [[ ! -f "$CONFIG_BASE.orig" ]]; then
    cp -f "$CONFIG_BASE" "$CONFIG_BASE.orig"
    info "saved pristine backup: $CONFIG_BASE.orig"
fi
# Per-run safety backup.
cp -f "$CONFIG_BASE" "$CONFIG_BASE.configure-kernel.bak"

changed=0
exposed_warn=0

# Parse a fragment line into SYMBOL. Returns the symbol name (CONFIG_FOO) or "".
sym_of() {
    local line="$1"
    if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blanks and pure comments (but NOT "# CONFIG_X is not set").
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" == \#* ]] && ! [[ "$line" =~ ^#\ CONFIG_[A-Za-z0-9_]+\ is\ not\ set$ ]]; then
        continue
    fi

    sym="$(sym_of "$line")"
    [[ -n "$sym" ]] || { info "WARN: ignoring unrecognized fragment line: $line"; continue; }

    # Already present, exactly as desired? -> no-op.
    if grep -qxF "$line" "$CONFIG_BASE"; then
        info "ok (unchanged): $line"
        continue
    fi

    # Is there ANY existing line for this symbol (set or "is not set")?
    if grep -qE "^($sym=|# $sym is not set)" "$CONFIG_BASE"; then
        # Replace it in place. Two simple sed exprs cover both existing forms;
        # whichever matches replaces the WHOLE line with the fragment line.
        # Escape the replacement text for sed.
        repl=$(printf '%s' "$line" | sed -e 's/[&/\]/\\&/g')
        sed -i \
            -e "s|^$sym=.*\$|$repl|" \
            -e "s|^# $sym is not set\$|$repl|" \
            "$CONFIG_BASE"
        info "edited:  $line"
        changed=1
    else
        # New symbol -> append. May be a newly-exposed symbol.
        printf '%s\n' "$line" >> "$CONFIG_BASE"
        info "appended (NEW symbol): $line"
        changed=1
        exposed_warn=1
    fi
done < "$FRAG"

if [[ "$changed" == 0 ]]; then
    info "no changes needed (already applied). $CONFIG_BASE"
else
    info "applied $FRAG to $CONFIG_BASE"
fi

cat >&2 <<'EOF'

configure-kernel: REMINDERS
  * Do NOT run olddefconfig / make clean on config_base — it strips ~64
    CONFIG_BCM_KF_* symbols and the build's syncconfig then prompts (EOF -> fail).
    Only ever edit config_base IN PLACE (which is what this script does).
  * Enabling a CONFIG that OPENS a sub-menu (e.g. CONFIG_FTRACE) makes the build's
    syncconfig prompt for every newly-VISIBLE symbol -> EOF -> build fails.
    If your build log shows a `(NEW)` prompt, add that symbol's default to your
    fragment (usually `# CONFIG_X is not set`) and re-apply, then rebuild. Iterate.
  * Verify after building with scripts/build-kernel.sh (checks config_data.gz).
EOF
