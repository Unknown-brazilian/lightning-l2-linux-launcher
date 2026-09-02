#!/bin/bash
# Lightning-L2 Linux launcher - first-run setup
# Sets up a dedicated Wine-GE + DXVK environment and points it at the
# player's existing Lineage II High Five client install.
set -e
set -o pipefail

# ---- Configurable (site operator: update if these ever move) ----
WINE_GE_URL="https://github.com/GloriousEggroll/wine-ge-custom/releases/download/GE-Proton8-26/wine-lutris-GE-Proton8-26-x86_64.tar.xz"
DXVK_URL="https://github.com/doitsujin/dxvk/releases/download/v2.3.1/dxvk-2.3.1.tar.gz"
SYSTEM_PATCH_URL="https://lightning-l2.com/lightning-l2-system.zip"
SYSTEM_PATCH_VERSION_URL="https://lightning-l2.com/lightning-l2-system-version.txt"
# -------------------------------------------------------------------

INSTALL_DIR="$HOME/.local/share/lightning-l2"
CONFIG_DIR="$HOME/.config/lightning-l2"
CONFIG_FILE="$CONFIG_DIR/config"
WINE_GE_DIR="$INSTALL_DIR/wine-ge"
WINEPREFIX="$INSTALL_DIR/prefix"
MARKER="$INSTALL_DIR/.setup_complete"
SYSTEM_PATCH_VERSION_FILE="$INSTALL_DIR/.system_patch_version"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

log() { echo "[Lightning-L2 setup] $*"; }

# --- 1. Ask for the client folder if we don't already know it ---
if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^CLIENT_DIR=' "$CONFIG_FILE" 2>/dev/null; then
    CLIENT_DIR=$(zenity --file-selection --directory \
        --title="Select your Lineage II High Five client folder" 2>/dev/null) || {
        zenity --error --text="Setup cancelled - no client folder selected." 2>/dev/null
        exit 1
    }

    if [ ! -f "$CLIENT_DIR/system/l2.exe" ] && [ ! -f "$CLIENT_DIR/LineageII.exe" ]; then
        zenity --error --text="That folder doesn't look like a Lineage II client (no l2.exe/LineageII.exe found). Please point to the folder containing 'system\\l2.exe'." 2>/dev/null
        exit 1
    fi

    echo "CLIENT_DIR=$CLIENT_DIR" > "$CONFIG_FILE"
else
    CLIENT_DIR=$(grep '^CLIENT_DIR=' "$CONFIG_FILE" | cut -d= -f2-)
fi

# --- 2. Apply the Lightning-L2 system patch, then strip the anti-cheat
#        driver files (GameGuard's kernel driver cannot load under Wine -
#        removing just the two .sys files while keeping GameGuard.des is
#        what lets the client start cleanly under Wine-GE) ---
(
echo "10"; echo "# Downloading Lightning-L2 system patch..."
curl -fSL -o "$INSTALL_DIR/system-patch.zip" "$SYSTEM_PATCH_URL"

echo "30"; echo "# Applying system patch..."
unzip -o -q "$INSTALL_DIR/system-patch.zip" -d "$CLIENT_DIR"

# A pre-existing, differently-cased file (e.g. "ItemName-E.DAT" from
# whatever client source this player started from) doesn't get overwritten
# by unzip on this case-sensitive filesystem - it just sits alongside the
# correct one, and which file Wine actually reads is undefined. Clean up
# any case-duplicate of ItemName-e.dat specifically (same reasoning as
# launch.sh's own re-sync path) so there's exactly one, unambiguous copy.
for stale in "$CLIENT_DIR"/system/[Ii][Tt][Ee][Mm][Nn][Aa][Mm][Ee]-[Ee].[Dd][Aa][Tt]; do
	[ -e "$stale" ] || continue
	[ "$stale" = "$CLIENT_DIR/system/ItemName-e.dat" ] && continue
	rm -f "$stale"
done

# Record the version we just applied, so launch.sh's own re-sync check
# (see launch.sh) doesn't immediately re-download the exact same patch on
# this install's very first launch. A failed fetch here just means the
# next launch's check does the (harmless, one-time-extra) re-download
# instead - not worth failing setup over.
curl -fsSL "$SYSTEM_PATCH_VERSION_URL" -o "$SYSTEM_PATCH_VERSION_FILE" 2>/dev/null || true

echo "40"; echo "# Removing Windows-only anti-cheat driver files..."
rm -f "$CLIENT_DIR/system/npkcusb.sys" "$CLIENT_DIR/system/npkcrypt.sys" "$CLIENT_DIR/system/npkcrypt.vxd"

# --- 3. Wine-GE ---
if [ ! -x "$WINE_GE_DIR/bin/wine" ]; then
    echo "50"; echo "# Downloading Wine-GE (one-time, ~230MB)..."
    curl -fSL -o "$INSTALL_DIR/wine-ge.tar.xz" "$WINE_GE_URL"
    echo "60"; echo "# Extracting Wine-GE..."
    mkdir -p "$WINE_GE_DIR"
    tar xf "$INSTALL_DIR/wine-ge.tar.xz" -C "$WINE_GE_DIR" --strip-components=1
    rm -f "$INSTALL_DIR/wine-ge.tar.xz"
fi

echo "70"; echo "# Initializing Wine prefix..."
export WINEPREFIX WINE="$WINE_GE_DIR/bin/wine" WINESERVER="$WINE_GE_DIR/bin/wineserver"
export PATH="$WINE_GE_DIR/bin:$PATH"
"$WINE_GE_DIR/bin/wineboot" -u >/dev/null 2>&1 || true
"$WINE_GE_DIR/bin/wineserver" -w

echo "80"; echo "# Installing Tahoma font (fixes missing UI text)..."
winetricks --unattended tahoma >/dev/null 2>&1

echo "85"; echo "# Registering MSXML (fixes a crash on destroying items)..."
winetricks --unattended msxml4 msxml6 >/dev/null 2>&1

echo "90"; echo "# Installing DXVK (Direct3D->Vulkan translation)..."
curl -fSL -o "$INSTALL_DIR/dxvk.tar.gz" "$DXVK_URL"
mkdir -p "$INSTALL_DIR/dxvk"
tar xf "$INSTALL_DIR/dxvk.tar.gz" -C "$INSTALL_DIR/dxvk" --strip-components=1
cp "$INSTALL_DIR/dxvk/x32/d3d9.dll" "$WINEPREFIX/drive_c/windows/syswow64/d3d9.dll"
rm -f "$INSTALL_DIR/dxvk.tar.gz"

echo "95"; echo "# Applying compatibility tweaks..."
"$WINE_GE_DIR/bin/wine" reg add "HKCU\\Software\\Wine\\Direct3D" /v StrictDrawOrdering /t REG_SZ /d enabled /f >/dev/null 2>&1
"$WINE_GE_DIR/bin/wineserver" -k 2>/dev/null || true

echo "100"; echo "# Done!"
) | zenity --progress --title="Setting up Lightning-L2" --text="Starting..." --percentage=0 --auto-close --width=420 2>/dev/null
SETUP_STATUS=$?

if [ "$SETUP_STATUS" -ne 0 ]; then
    zenity --error --text="Setup failed or was cancelled. Please try again - if this keeps happening, ask for help in the Lightning-L2 Discord." 2>/dev/null
    exit 1
fi

touch "$MARKER"
log "Setup complete."
