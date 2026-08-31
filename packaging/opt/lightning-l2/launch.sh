#!/bin/bash
# Lightning-L2 Linux launcher - entry point
set -e

INSTALL_DIR="$HOME/.local/share/lightning-l2"
CONFIG_DIR="$HOME/.config/lightning-l2"
CONFIG_FILE="$CONFIG_DIR/config"
WINE_GE_DIR="$INSTALL_DIR/wine-ge"
WINEPREFIX="$INSTALL_DIR/prefix"
MARKER="$INSTALL_DIR/.setup_complete"
SHORTCUT_ASKED="$CONFIG_DIR/.shortcut_asked"
LOG_DIR="$INSTALL_DIR/logs"

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
