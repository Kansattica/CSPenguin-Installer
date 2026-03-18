#!/usr/bin/env bash
# uninstall script!
set -euo pipefail

WINEPREFIX="${WINEPREFIX:-$HOME/.wine-csp}"
DESKTOP_FILE="$HOME/.local/share/applications/clipstudiopaint.desktop"
DESKTOP_STUDIO="$HOME/.local/share/applications/clipstudio.desktop"
DESKTOP_SHORTCUT="$HOME/Desktop/clipstudiopaint.desktop"
DESKTOP_SHORTCUT_STUDIO="$HOME/Desktop/clipstudio.desktop"
LAUNCH_DIR="$HOME/.local/share/cspenguin"
DOWNLOAD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/csp-install"
WINE_UNIX="$(dirname "$(command -v wine)")/../lib64/wine/x86_64-unix"
[[ -d "$WINE_UNIX" ]] || WINE_UNIX="$(dirname "$(command -v wine)")/../lib/wine/x86_64-unix"
GST_BACKUP="$LAUNCH_DIR/winegstreamer.so.bak"

ok()    { echo "  + $1"; }
warn()  { echo "  ! $1"; }

echo "  This will remove:"
echo "  - Wine prefix: $WINEPREFIX"
echo "  - Desktop entries: $DESKTOP_FILE, $DESKTOP_STUDIO"
echo "  - Desktop shortcuts: $DESKTOP_SHORTCUT, $DESKTOP_SHORTCUT_STUDIO"
echo "  - Launch scripts: $LAUNCH_DIR"
echo "  - Thumbnailer: /usr/local/bin/clip-thumbnailer"
echo ""
read -rp "Are you sure? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

[[ -d "$WINEPREFIX" ]]              && { rm -rf "$WINEPREFIX";                ok "$WINEPREFIX"; }              || warn "$WINEPREFIX not found"
[[ -f "$DESKTOP_FILE" ]]            && { rm -f  "$DESKTOP_FILE";            ok "$DESKTOP_FILE"; }            || warn "$DESKTOP_FILE not found"
[[ -f "$DESKTOP_STUDIO" ]]          && { rm -f  "$DESKTOP_STUDIO";          ok "$DESKTOP_STUDIO"; }          || warn "$DESKTOP_STUDIO not found"
[[ -f "$DESKTOP_SHORTCUT" ]]        && { rm -f  "$DESKTOP_SHORTCUT";        ok "$DESKTOP_SHORTCUT"; }        || warn "$DESKTOP_SHORTCUT not found"
[[ -f "$DESKTOP_SHORTCUT_STUDIO" ]] && { rm -f  "$DESKTOP_SHORTCUT_STUDIO"; ok "$DESKTOP_SHORTCUT_STUDIO"; } || warn "$DESKTOP_SHORTCUT_STUDIO not found"
# restore winegstreamer.so before removing the backup
if [[ -d "$WINE_UNIX" ]] && [[ -f "$WINE_UNIX/winegstreamer.so" ]]; then
    if [[ -f "$GST_BACKUP" ]]; then
        sudo cp "$GST_BACKUP" "$WINE_UNIX/winegstreamer.so" 2>/dev/null && ok "winegstreamer.so restored" \
            || { warn "could not restore winegstreamer.so (needs root)"; warn "fix manually: sudo cp $GST_BACKUP $WINE_UNIX/winegstreamer.so"; }
    else
        sudo rm -f "$WINE_UNIX/winegstreamer.so" 2>/dev/null && ok "winegstreamer.so removed" \
            || warn "could not remove winegstreamer.so (needs root), run: sudo rm $WINE_UNIX/winegstreamer.so"
    fi
fi
[[ -d "$LAUNCH_DIR" ]]              && { rm -rf "$LAUNCH_DIR";              ok "$LAUNCH_DIR"; }              || warn "$LAUNCH_DIR not found"
[[ -d "$DOWNLOAD_CACHE" ]]          && { rm -rf "$DOWNLOAD_CACHE";          ok "$DOWNLOAD_CACHE"; }          || true


# thumbnailer
[[ -f "/usr/local/bin/clip-thumbnailer" ]] && \
    { sudo rm -f "/usr/local/bin/clip-thumbnailer" && ok "clip-thumbnailer removed"; } \
    || true
[[ -f "/usr/share/thumbnailers/clip.thumbnailer" ]] && \
    { sudo rm -f "/usr/share/thumbnailers/clip.thumbnailer" && ok "thumbnailer entry removed"; } \
    || true
if [[ -f "/usr/share/mime/packages/clip.xml" ]]; then
    sudo rm -f "/usr/share/mime/packages/clip.xml"
    sudo update-mime-database /usr/share/mime 2>/dev/null || true
    ok "MIME type removed"
fi

# wineserver pre-warm service
if systemctl --user is-enabled csp-wineserver.service &>/dev/null; then
    systemctl --user disable --now csp-wineserver.service 2>/dev/null && ok "wineserver service removed" \
        || warn "could not remove wineserver service"
fi
[[ -f "$HOME/.config/systemd/user/csp-wineserver.service" ]] && \
    rm -f "$HOME/.config/systemd/user/csp-wineserver.service"
systemctl --user daemon-reload 2>/dev/null || true

# esync config
[[ -f "$HOME/.config/systemd/user.conf.d/cspenguin-limits.conf" ]] && \
    rm -f "$HOME/.config/systemd/user.conf.d/cspenguin-limits.conf" && ok "esync systemd config removed"
[[ -f "/etc/security/limits.d/cspenguin.conf" ]] && \
    { sudo rm -f "/etc/security/limits.d/cspenguin.conf" 2>/dev/null && ok "esync limits.d config removed" \
      || warn "could not remove /etc/security/limits.d/cspenguin.conf (needs root)"; }

# Clean up winemenubuilder entries created by Wine during CSP install

rm -f  "$HOME/Desktop/CLIP STUDIO.desktop"
rm -rf "$HOME/.local/share/applications/wine/Programs/CLIP STUDIO"

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
kbuildsycoca6 2>/dev/null || kbuildsycoca5 2>/dev/null || true

echo ""
echo "  done."
