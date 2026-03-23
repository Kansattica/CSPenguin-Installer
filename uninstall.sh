#!/usr/bin/env bash
# uninstall script!
set -euo pipefail

WINEPREFIX="${WINEPREFIX:-$HOME/.wine-csp}"
LAUNCHER_DIR="$HOME/.local/share/cspenguin"
DOWNLOAD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/csp-install"

DESKTOP_FILE="$HOME/.local/share/applications/clipstudiopaint.desktop"
DESKTOP_STUDIO="$HOME/.local/share/applications/clipstudio.desktop"
DESKTOP_SHORTCUT="$HOME/Desktop/clipstudiopaint.desktop"
DESKTOP_SHORTCUT_STUDIO="$HOME/Desktop/clipstudio.desktop"

THUMBNAILER_BIN="$HOME/.local/bin/clip-thumbnailer"
THUMBNAILER_ENTRY="$HOME/.local/share/thumbnailers/clip.thumbnailer"
MIME_FILE="$HOME/.local/share/mime/packages/clip.xml"

ok()    { echo "  + $1"; }
warn()  { echo "  ! $1"; }

remove_file() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then
        rm -f "$path" && ok "$label removed" || warn "could not remove $label"
    fi
}

remove_dir() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then
        rm -rf "$path" && ok "$label removed" || warn "could not remove $label"
    fi
}

echo ""
echo "  This will remove:"
echo "  - Wine prefix: $WINEPREFIX"
echo "  - Launcher + bundled Wine: $LAUNCHER_DIR"
echo "  - Desktop entries"
echo "  - Thumbnailer: $THUMBNAILER_BIN"
echo "  - MIME type, thumbnailer entry"
echo "  - Wineserver service, esync config"
echo "  - KDE window rules (if any)"
echo ""
read -rp "  Are you sure? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "  Aborted."; exit 0; }

echo ""

# wineprefix
remove_dir "$WINEPREFIX" "wineprefix"

# desktop entries
remove_file "$DESKTOP_FILE" "desktop entry (clipstudiopaint)"
remove_file "$DESKTOP_STUDIO" "desktop entry (clipstudio)"
remove_file "$DESKTOP_SHORTCUT" "desktop shortcut (clipstudiopaint)"
remove_file "$DESKTOP_SHORTCUT_STUDIO" "desktop shortcut (clipstudio)"

# winemenubuilder leftovers
rm -f "$HOME/Desktop/CLIP STUDIO.desktop" 2>/dev/null
rm -rf "$HOME/.local/share/applications/wine/Programs/CLIP STUDIO" 2>/dev/null

# launcher dir (includes bundled wine, dcomp.dll, launch scripts)
remove_dir "$LAUNCHER_DIR" "launcher + bundled wine"

# download cache
remove_dir "$DOWNLOAD_CACHE" "download cache"

# thumbnailer
remove_file "$THUMBNAILER_BIN" "clip-thumbnailer"
remove_file "$THUMBNAILER_ENTRY" "thumbnailer entry"

# mime type
if [[ -f "$MIME_FILE" ]]; then
    rm -f "$MIME_FILE" && ok "MIME type removed" || warn "could not remove MIME type"
    update-mime-database "$HOME/.local/share/mime" 2>/dev/null || true
fi

# wineserver pre-warm service
if systemctl --user is-enabled csp-wineserver.service &>/dev/null; then
    systemctl --user disable --now csp-wineserver.service 2>/dev/null && ok "wineserver service disabled" \
        || warn "could not disable wineserver service"
fi
remove_file "$HOME/.config/systemd/user/csp-wineserver.service" "wineserver service file"
systemctl --user daemon-reload 2>/dev/null || true

# esync config
remove_file "$HOME/.config/systemd/user.conf.d/cspenguin-limits.conf" "esync systemd config"
if [[ -f "/etc/security/limits.d/cspenguin.conf" ]]; then
    sudo rm -f "/etc/security/limits.d/cspenguin.conf" 2>/dev/null && ok "esync limits.d config removed" \
        || warn "could not remove /etc/security/limits.d/cspenguin.conf (needs root)"
fi

# KDE window rules
_kwinrc="$HOME/.config/kwinrulesrc"
if [[ -f "$_kwinrc" ]] && grep -q "CSPenguin:" "$_kwinrc" 2>/dev/null; then
    # find and remove CSPenguin rule groups
    _rules_removed=0
    for _group in $(grep -B1 "CSPenguin:" "$_kwinrc" | grep '^\[' | tr -d '[]'); do
        sed -i "/^\[$_group\]/,/^\[/{ /^\[$_group\]/d; /^\[/!d; }" "$_kwinrc"
        _rules_removed=$((_rules_removed + 1))
    done
    if [[ $_rules_removed -gt 0 ]]; then
        qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || \
            dbus-send --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
        ok "KDE window rules removed ($_rules_removed rules)"
    fi
fi

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
kbuildsycoca6 2>/dev/null || kbuildsycoca5 2>/dev/null || true

echo ""
echo "  done."
