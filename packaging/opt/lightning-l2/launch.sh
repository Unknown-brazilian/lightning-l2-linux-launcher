#!/bin/bash
# Lightning-L2 Linux launcher - entry point
set -e

# Kept in sync with setup.sh's own copy - both need the real URL, and
# launch.sh can't easily source setup.sh's config block without also
# re-running its first-run prompts.
SYSTEM_PATCH_URL="https://lightning-l2.com/lightning-l2-system.zip"
SYSTEM_PATCH_VERSION_URL="https://lightning-l2.com/lightning-l2-system-version.txt"

INSTALL_DIR="$HOME/.local/share/lightning-l2"
CONFIG_DIR="$HOME/.config/lightning-l2"
CONFIG_FILE="$CONFIG_DIR/config"
WINE_GE_DIR="$INSTALL_DIR/wine-ge"
WINEPREFIX="$INSTALL_DIR/prefix"
MARKER="$INSTALL_DIR/.setup_complete"
SHORTCUT_ASKED="$CONFIG_DIR/.shortcut_asked"
LOG_DIR="$INSTALL_DIR/logs"
SYSTEM_PATCH_VERSION_FILE="$INSTALL_DIR/.system_patch_version"

# Always log to a file - a Terminal=true window can close before anyone
# reads it, but the log survives so problems can be diagnosed after the
# fact (this file, not the terminal, is what to check/share for support).
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launch_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[Lightning-L2] Log: $LOG_FILE"
# Keep only the last 10 launch logs.
ls -1t "$LOG_DIR"/launch_*.log 2>/dev/null | tail -n +11 | xargs -r rm -f

# If setup fails before we even get to launching Wine, keep the terminal
# open long enough to actually read the error instead of it flashing shut.
trap 'echo; echo "[Lightning-L2] Startup failed - see $LOG_FILE"; read -p "Press Enter to close..." _' ERR

# Guard against double-clicks (or impatient re-clicks) racing a second
# Wine process against the same prefix during the risky early-init window
# (this is what crashed a helper process earlier). The lock is released
# once this instance is confirmed stable, so launching a second account
# for multiboxing afterwards still works fine.
LOCK_FILE="$INSTALL_DIR/.launch.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[Lightning-L2] Already starting - ignoring extra launch."
    zenity --info --title="Lightning-L2" --text="Lightning-L2 is already starting. Give it a few seconds." --timeout=3 2>/dev/null || true
    exit 0
fi

# First run (or a previous run was interrupted before finishing): bootstrap.
if [ ! -f "$MARKER" ]; then
    /opt/lightning-l2/setup.sh
fi

CLIENT_DIR=$(grep '^CLIENT_DIR=' "$CONFIG_FILE" | cut -d= -f2-)

# Small one-off patches for installs that already ran setup.sh before a fix
# was added to it - each runs at most once, tracked by its own marker, so
# updating the .deb doesn't force a full from-scratch re-setup.
MSXML_PATCHED="$INSTALL_DIR/.msxml_patched"
if [ ! -f "$MSXML_PATCHED" ]; then
    echo "[Lightning-L2] One-time fix: registering MSXML (destroy-item crash)..."
    export WINEPREFIX WINE="$WINE_GE_DIR/bin/wine" WINESERVER="$WINE_GE_DIR/bin/wineserver"
    export PATH="$WINE_GE_DIR/bin:$PATH"
    winetricks --unattended msxml4 msxml6 >/dev/null 2>&1 || true
    touch "$MSXML_PATCHED"
fi

# Re-sync the system folder patch if the site has published a newer one -
# a real, standing mechanism (not another one-off marker) so every future
# system-patch fix (item names, NPC data, etc.) reaches already-installed
# players automatically on their next launch, without needing a new .deb
# or another block added here. Compares a tiny remote version file against
# the one recorded locally (by setup.sh on first install, or by this same
# block previously) - only re-downloads the ~26MB zip when they differ.
# Entirely best-effort: any network failure here is silently ignored and
# falls through to launching normally - never blocks play over a patch
# check, and never touches CLIENT_DIR if REMOTE_VERSION comes back empty.
#
# IMPORTANT (fixed in v1.7, was a real bug in v1.5/v1.6): the version
# marker must only ever be written after `unzip` itself reports success.
# The original version did `unzip ... 2>/dev/null || true` and then wrote
# the marker unconditionally - meaning a failed extraction (permissions,
# a case-sensitivity mismatch between the zip's paths and an existing
# differently-cased file on this Linux filesystem, disk full, etc.) still
# got recorded as "up to date", silently and permanently masking the
# failure - the exact class of bug this mechanism exists to prevent.
#
# v1.8: v1.7's fix only stops *new* false-positive markers - it does
# nothing for an install that already has one on disk from the buggy
# v1.5/v1.6 code, which is exactly what a real report turned up: a
# player's local marker already read the current version, but their
# actual system/ItemName-e.dat on disk was still the untouched original
# (proven by matching the pre-patch file's exact size and mtime) - v1.7
# saw "already up to date" and skipped re-extracting forever. One-time,
# marker-gated (same pattern as MSXML_PATCHED below): force exactly one
# re-sync per install by discarding whatever SYSTEM_PATCH_VERSION_FILE
# currently claims, so this class of already-poisoned marker gets
# corrected once under the now-fixed exit-code-checked logic, without
# forcing a full re-setup or re-forcing it on every future launch.
V18_FORCED_RESYNC="$INSTALL_DIR/.v18_forced_resync_done"
if [ ! -f "$V18_FORCED_RESYNC" ]; then
    echo "[Lightning-L2] v1.8: discarding any existing system patch version marker to force one verified re-sync..."
    rm -f "$SYSTEM_PATCH_VERSION_FILE"
    touch "$V18_FORCED_RESYNC"
fi

echo "[Lightning-L2] Checking for system patch updates..."
REMOTE_VERSION=$(curl -fsSL --max-time 5 "$SYSTEM_PATCH_VERSION_URL" 2>/dev/null || true)
LOCAL_VERSION=$(cat "$SYSTEM_PATCH_VERSION_FILE" 2>/dev/null || true)
echo "[Lightning-L2] Local system patch version: '${LOCAL_VERSION:-none}', remote: '${REMOTE_VERSION:-unreachable}'"
if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
    echo "[Lightning-L2] System patch update available ($LOCAL_VERSION -> $REMOTE_VERSION) - re-syncing..."
    if curl -fsSL --max-time 60 -o "$INSTALL_DIR/system-patch.zip" "$SYSTEM_PATCH_URL" 2>/dev/null; then
        UNZIP_ERR="$INSTALL_DIR/.system_patch_unzip_error.log"
        if unzip -o -q "$INSTALL_DIR/system-patch.zip" -d "$CLIENT_DIR" 2>"$UNZIP_ERR"; then
            rm -f "$UNZIP_ERR"
            rm -f "$CLIENT_DIR/system/npkcusb.sys" "$CLIENT_DIR/system/npkcrypt.sys" "$CLIENT_DIR/system/npkcrypt.vxd"
            # unzip succeeding doesn't guarantee the right file actually got
            # overwritten - a Linux (case-sensitive) filesystem holding an
            # existing "ItemName-E.DAT" or similar (differently-cased from
            # this zip's "system/ItemName-e.dat") would just get a second,
            # separate file created alongside it, not a real overwrite, and
            # which one the client ends up reading under Wine is undefined.
            # This exact class of bug already bit this project once before
            # (case-duplicate files in a Wine-prefix client folder, found
            # and cleaned up in an earlier session) - clean it up here too,
            # keeping only the file this zip actually intends.
            for stale in "$CLIENT_DIR"/system/[Ii][Tt][Ee][Mm][Nn][Aa][Mm][Ee]-[Ee].[Dd][Aa][Tt]; do
                [ -e "$stale" ] || continue
                [ "$stale" = "$CLIENT_DIR/system/ItemName-e.dat" ] && continue
                echo "[Lightning-L2] Removing stale case-duplicate: $stale"
                rm -f "$stale"
            done
            # Log exactly what's on disk now, so a future report can be
            # diagnosed from this log alone instead of another round of
            # back-and-forth diagnostic commands.
            if [ -f "$CLIENT_DIR/system/ItemName-e.dat" ]; then
                echo "[Lightning-L2] system/ItemName-e.dat now: $(md5sum "$CLIENT_DIR/system/ItemName-e.dat" | cut -d' ' -f1), $(stat -c '%s bytes, modified %y' "$CLIENT_DIR/system/ItemName-e.dat" 2>/dev/null)"
            else
                echo "[Lightning-L2] WARNING: system/ItemName-e.dat does not exist after extraction - the zip's internal layout may not match this client's system/ folder."
            fi
            echo "$REMOTE_VERSION" > "$SYSTEM_PATCH_VERSION_FILE"
            echo "[Lightning-L2] System patch updated to $REMOTE_VERSION."
        else
            echo "[Lightning-L2] System patch extraction failed - marker NOT updated, will retry next launch. unzip said:"
            sed 's/^/[Lightning-L2]   /' "$UNZIP_ERR" 2>/dev/null || true
        fi
    else
        echo "[Lightning-L2] Could not fetch system patch update - will retry next launch."
    fi
else
    echo "[Lightning-L2] System patch already up to date."
fi

# Offer a Desktop shortcut once, after the player has something working.
if [ ! -f "$SHORTCUT_ASKED" ]; then
    mkdir -p "$CONFIG_DIR"
    touch "$SHORTCUT_ASKED"
    if [ -d "$HOME/Desktop" ] && command -v zenity >/dev/null; then
        if zenity --question --title="Lightning-L2" \
            --text="Add a Lightning-L2 shortcut to your Desktop?" 2>/dev/null; then
            cp /usr/share/applications/lightning-l2.desktop "$HOME/Desktop/lightning-l2.desktop"
            chmod +x "$HOME/Desktop/lightning-l2.desktop"
            gio set "$HOME/Desktop/lightning-l2.desktop" metadata::trusted true 2>/dev/null || true
        fi
    fi
fi

# --- Launch ---
export WINEPREFIX
export WINEDLLOVERRIDES="d3d9=n"
# Deliberately unset - these cause an NV-GLX BadMatch crash with this
# renderer combo; DXVK picks the right GPU on its own via Vulkan.
unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME

cd "$CLIENT_DIR/system"
"$WINE_GE_DIR/bin/wine" l2.exe &
WINE_PID=$!

# Hold the lock through the risky early-init window only, then release it -
# a second launch after this point (e.g. multiboxing a second account) is
# then free to proceed normally.
sleep 8
flock -u 200

wait "$WINE_PID"
