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
# The genuine, unmodified base client - same file connect.html links to.
# We don't host or modify this; it's just automated here so players who
# only grabbed the launcher (a common mistake) don't hit a dead end.
CLIENT_URL="https://www.lineage2.org.uk/?wpdmdl=126"
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

# Where an auto-downloaded client lands - the standard Downloads folder
# when available (xdg-user-dirs), falling back to ~/Downloads otherwise.
DOWNLOAD_BASE=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
[ -z "$DOWNLOAD_BASE" ] && DOWNLOAD_BASE="$HOME/Downloads"
CLIENT_DL_DIR="$DOWNLOAD_BASE/Lineage2"

# Case-insensitive: different client packages ship system/l2.exe under
# either casing, and a Linux filesystem cares. Returning nothing found is
# the normal case (first run, no client yet) - every call site below
# guards this with `|| true` since set -e is active script-wide and would
# otherwise treat "nothing found" as a fatal error and abort setup.
find_client_root() {
    local exe
    [ -d "$1" ] || return 1
    exe=$(find "$1" -maxdepth 4 -ipath "*/system/l2.exe" 2>/dev/null | head -n1) || true
    [ -n "$exe" ] && dirname "$(dirname "$exe")"
}

# --- 1. Locate (or fetch) the player's Lineage II client folder ---
if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^CLIENT_DIR=' "$CONFIG_FILE" 2>/dev/null; then
    # A previous auto-download can still be on disk even with no config
    # (e.g. after the troubleshooting guide's "reset everything") - reuse
    # it instead of fetching 6GB again.
    CLIENT_DIR=$(find_client_root "$CLIENT_DL_DIR") || true

    if [ -z "$CLIENT_DIR" ] && zenity --question --title="Lightning-L2 setup" \
        --text="No Lineage II client was found on this computer.\n\nMost players who get stuck here downloaded only the launcher and skipped the base game client - it's a separate ~5.6GB download that Lightning-L2 doesn't bundle.\n\nDownload it automatically now?" \
        --ok-label="Download it for me (~5.6GB)" --cancel-label="I already have it" 2>/dev/null; then

        AVAIL_KB=$(df --output=avail -k "$DOWNLOAD_BASE" 2>/dev/null | tail -n1) || true
        REQUIRED_KB=$((14 * 1024 * 1024))  # zip + extracted copy, with margin
        if [ -z "$AVAIL_KB" ] || [ "$AVAIL_KB" -lt "$REQUIRED_KB" ]; then
            zenity --error --text="Not enough free space in $DOWNLOAD_BASE for the client download (need ~14GB free). Free up space and try again, or point Lightning-L2 at a client you already have." 2>/dev/null
        else
            mkdir -p "$CLIENT_DL_DIR"
            ZIP_PATH="$CLIENT_DL_DIR/lineage2-highfive-client.zip"

            # `|| true` throughout this block: set -e/pipefail are active
            # script-wide, and a failure here (or in curl/unzip below) must
            # fall through to this block's own status checks and error
            # dialogs, not silently kill the whole setup mid-progress-bar.
            CONTENT_LEN=$(curl -sIL --max-time 20 "$CLIENT_URL" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}') || true

            # -C - resumes a partial download from a prior cancelled/failed
            # attempt instead of restarting the ~5.6GB transfer from zero.
            curl -fSL -C - -o "$ZIP_PATH" "$CLIENT_URL" &
            CURL_PID=$!
            (
                while kill -0 "$CURL_PID" 2>/dev/null; do
                    CUR=$(stat -c%s "$ZIP_PATH" 2>/dev/null || echo 0)
                    if [ -n "$CONTENT_LEN" ] && [ "$CONTENT_LEN" -gt 0 ] 2>/dev/null; then
                        PCT=$(( CUR * 100 / CONTENT_LEN ))
                        [ "$PCT" -gt 99 ] && PCT=99
                    else
                        PCT=50
                    fi
                    echo "$PCT"
                    echo "# Downloading Lineage II client: $(( CUR / 1024 / 1024 ))MB$( [ -n "$CONTENT_LEN" ] && echo "/$(( CONTENT_LEN / 1024 / 1024 ))MB" )"
                    sleep 1
                done
                # Always land on 100 so --auto-close actually closes the
                # dialog - a stall on some percent under 100 would leave it
                # sitting open, blocking the rest of setup on a manual close.
                echo "100"; echo "# Download complete."
            ) | zenity --progress --title="Lightning-L2 setup" --text="Starting download..." --percentage=0 --width=460 --auto-close 2>/dev/null || true
            CURL_STATUS=0
            wait "$CURL_PID" || CURL_STATUS=$?

            if [ "$CURL_STATUS" -ne 0 ]; then
                rm -f "$ZIP_PATH"
                zenity --error --text="Downloading the client failed (network error or the mirror is unreachable). Please download it manually from lineage2.org.uk and point Lightning-L2 at that folder instead." 2>/dev/null
            elif ! unzip -tq "$ZIP_PATH" >/dev/null 2>&1; then
                rm -f "$ZIP_PATH"
                zenity --error --text="The downloaded client file was corrupted. Please try again, or download it manually from lineage2.org.uk." 2>/dev/null
            else
                unzip -oq "$ZIP_PATH" -d "$CLIENT_DL_DIR" &
                UNZIP_PID=$!
                (
                    while kill -0 "$UNZIP_PID" 2>/dev/null; do
                        echo "# Extracting client files - this takes a few minutes..."
                        sleep 1
                    done
                    echo "100"
                ) | zenity --progress --title="Lightning-L2 setup" --text="Extracting client..." --pulsate --auto-close --width=420 2>/dev/null || true
                UNZIP_STATUS=0
                wait "$UNZIP_PID" || UNZIP_STATUS=$?

                if [ "$UNZIP_STATUS" -eq 0 ]; then
                    rm -f "$ZIP_PATH"
                    CLIENT_DIR=$(find_client_root "$CLIENT_DL_DIR") || true
                fi

                if [ -z "$CLIENT_DIR" ]; then
                    zenity --error --text="The downloaded client didn't extract correctly. Please download it manually from lineage2.org.uk and point Lightning-L2 at that folder instead." 2>/dev/null
                fi
            fi
        fi
    fi

    # Either auto-detection/download above found nothing, or the player
    # chose "I already have it" - fall back to asking directly.
    if [ -z "$CLIENT_DIR" ]; then
        CLIENT_DIR=$(zenity --file-selection --directory \
            --title="Select your Lineage II High Five client folder" 2>/dev/null) || {
            zenity --error --text="Setup cancelled - no client folder selected." 2>/dev/null
            exit 1
        }

        if [ ! -f "$CLIENT_DIR/system/l2.exe" ] && [ ! -f "$CLIENT_DIR/LineageII.exe" ]; then
            zenity --error --text="That folder doesn't look like a Lineage II client (no l2.exe/LineageII.exe found). Please point to the folder containing 'system\\l2.exe'." 2>/dev/null
            exit 1
        fi
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
# v1.9: fetch the current version first (its own endpoint is never
# cached) and use it to cache-bust the actual zip download - the bare
# zip URL sits behind a CDN cache for hours, confirmed live to serve a
# stale build after a real deploy. Falls back to the bare URL if the
# version endpoint is unreachable, matching this script's existing
# fail-forward style elsewhere - still correct on a fresh install where
# nothing has ever been cached with the wrong content yet.
CURRENT_PATCH_VERSION=$(curl -fsSL "$SYSTEM_PATCH_VERSION_URL" 2>/dev/null || true)
if [ -n "$CURRENT_PATCH_VERSION" ]; then
	curl -fSL -o "$INSTALL_DIR/system-patch.zip" "${SYSTEM_PATCH_URL}?v=${CURRENT_PATCH_VERSION}"
else
	curl -fSL -o "$INSTALL_DIR/system-patch.zip" "$SYSTEM_PATCH_URL"
fi

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
# this install's very first launch. Reuses $CURRENT_PATCH_VERSION from
# the fetch above (same value that was actually downloaded) rather than
# querying again - avoids a pointless second network call and closes off
# any chance of the two fetches disagreeing if a deploy happens to land
# in between them. A missing value here just means the next launch's
# check does the (harmless, one-time-extra) re-download instead - not
# worth failing setup over.
if [ -n "$CURRENT_PATCH_VERSION" ]; then
	echo -n "$CURRENT_PATCH_VERSION" > "$SYSTEM_PATCH_VERSION_FILE"
fi

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
