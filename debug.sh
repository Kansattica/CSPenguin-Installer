#!/usr/bin/env bash
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-csp}"
LAUNCHER_DIR="$HOME/.local/share/cspenguin"
WINE_BIN="$LAUNCHER_DIR/wine-11.4/bin/wine"
SYS32="$WINEPREFIX/drive_c/windows/system32"
CSP_EXE="$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5/CLIP STUDIO PAINT/CLIPStudioPaint.exe"

ok()   { echo "  + $1"; }
warn() { echo "  ! $1"; }
info() { echo "  - $1"; }

check() {
    local label="$1" path="$2"
    [[ -e "$path" ]] && ok "$label" || warn "$label MISSING ($path)"
}

echo ""
echo "[system]"
grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null | sed 's/^/  /'
info "kernel: $(uname -r)"
info "desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    warn "display: Wayland (Wine tablet/pen pressure requires X11 or XWayland)"
elif [[ -n "${DISPLAY:-}" ]]; then
    ok "display: X11 ($DISPLAY)"
else
    warn "display: not set"
fi

echo ""
echo "[bundled wine]"
if [[ -x "$WINE_BIN" ]]; then
    _ver="$("$WINE_BIN" --version 2>/dev/null)"
    if echo "$_ver" | grep -qi 'staging'; then
        warn "version: $_ver (staging detected — should be plain wine-11.4)"
    else
        ok "version: $_ver"
    fi
    if grep -q 'wine-11.4' "$LAUNCHER_DIR/csp-launch.sh" 2>/dev/null; then
        ok "launch script points to bundled wine"
    else
        warn "launch script may not point to bundled wine"
        info "wine path in csp-launch.sh: $(grep 'WINE_DIR\|wine-' "$LAUNCHER_DIR/csp-launch.sh" 2>/dev/null | head -1 | sed 's/^ *//')"
    fi
else
    warn "bundled wine binary not found at $WINE_BIN"
    info "contents of $LAUNCHER_DIR:"
    ls "$LAUNCHER_DIR/" 2>/dev/null | sed 's/^/    /' || echo "    (directory not found)"
fi
_sys_wine="$(wine --version 2>/dev/null || echo 'not found')"
info "system wine: $_sys_wine"

echo ""
echo "[wineprefix]"
if [[ -d "$WINEPREFIX" ]]; then
    ok "prefix found: $WINEPREFIX"
    check "CSP executable" "$CSP_EXE"
    check "dxvk.conf" "$WINEPREFIX/dxvk.conf"
    check "dcomp.dll (sys32)" "$SYS32/dcomp.dll"
    check "libwinpthread-1.dll (sys32)" "$SYS32/libwinpthread-1.dll"
    check "mfplat.dll (sys32)" "$SYS32/mfplat.dll"
    check "mfreadwrite.dll (sys32)" "$SYS32/mfreadwrite.dll"
    check "winegstreamer.dll (sys32)" "$SYS32/winegstreamer.dll"
    _wt_log="$WINEPREFIX/winetricks.log"
    if [[ -f "$_wt_log" ]]; then
        for pkg in corefonts cjkfonts vcrun2022 dotnet48 dxvk vkd3d; do
            grep -qx "$pkg" "$_wt_log" && ok "winetricks: $pkg" || warn "winetricks: $pkg NOT in log"
        done
    else
        warn "winetricks.log not found — winetricks may not have run"
    fi
else
    warn "wineprefix not found at $WINEPREFIX"
fi

echo ""
echo "[launcher]"
check "csp-launch.sh" "$LAUNCHER_DIR/csp-launch.sh"
check "clipstudio-launch.sh" "$LAUNCHER_DIR/clipstudio-launch.sh"
check "dcomp.dll (launcher dir)" "$LAUNCHER_DIR/dcomp.dll"
check "desktop entry: clipstudiopaint" "$HOME/.local/share/applications/clipstudiopaint.desktop"
check "desktop entry: clipstudio" "$HOME/.local/share/applications/clipstudio.desktop"
check "thumbnailer binary" "$HOME/.local/bin/clip-thumbnailer"
check "MIME type: clip.xml" "$HOME/.local/share/mime/packages/clip.xml"
check "thumbnailer entry" "$HOME/.local/share/thumbnailers/clip.thumbnailer"

echo ""
echo "[wineserver service]"
if systemctl --user is-enabled csp-wineserver.service &>/dev/null; then
    _state="$(systemctl --user is-active csp-wineserver.service 2>/dev/null)"
    ok "csp-wineserver.service enabled, state: $_state"
else
    info "csp-wineserver.service not enabled (optional)"
fi

echo ""
echo "[esync / fsync]"
_nofile="$(ulimit -n 2>/dev/null || echo 0)"
if [[ "$_nofile" -ge 524288 ]]; then
    ok "file descriptor limit: $_nofile"
else
    warn "file descriptor limit: $_nofile (should be 524288 for esync)"
fi
grep -rq 'cspenguin' /etc/security/limits.d/ 2>/dev/null && ok "limits.d entry found" || info "no limits.d entry"

echo ""
echo "[vulkan]"
if command -v vulkaninfo &>/dev/null; then
    _vkout="$(vulkaninfo --summary 2>/dev/null)" \
        || _vkout="$(vulkaninfo 2>/dev/null)"
    echo "$_vkout" | grep -E 'deviceName|driverVersion' | head -5 | sed 's/^/  /' \
        || warn "vulkaninfo returned no device info"
else
    warn "vulkaninfo not found (install vulkan-tools to check)"
fi

echo ""
echo "[tablet drivers]"
echo "  kernel modules:"
_modules="$(lsmod | grep -Ei 'wacom|uclogic|hid_huion|tablet')"
[[ -n "$_modules" ]] && echo "$_modules" | sed 's/^/    /' || echo "    none found"
echo "  input devices:"
_inputdevs="$(grep -A5 -Ei 'wacom|huion|tablet|stylus|pen' /proc/bus/input/devices 2>/dev/null)"
[[ -n "$_inputdevs" ]] && echo "$_inputdevs" | sed 's/^/    /' || echo "    none found"
echo "  xinput:"
_xinput_list="$(xinput list 2>/dev/null)"
_xinput_tablets="$(echo "$_xinput_list" | grep -Ei 'wacom|huion|tablet|stylus|pen')"
if [[ -n "$_xinput_tablets" ]]; then
    echo "$_xinput_tablets" | sed 's/^/    /'
    _stylus_line="$(echo "$_xinput_tablets" | grep -Ei 'stylus|pen' | head -1)"
    [[ -z "$_stylus_line" ]] && _stylus_line="$(echo "$_xinput_tablets" | head -1)"
    _dev_id="$(echo "$_stylus_line" | grep -o 'id=[0-9]*' | head -1 | cut -d= -f2)"
    if [[ -n "$_dev_id" ]]; then
        echo "  pressure axis (device $_dev_id):"
        xinput list-props "$_dev_id" 2>/dev/null | grep -i 'pressure\|abs' | sed 's/^/    /' || echo "    (none)"
    fi
else
    echo "    none found (or xinput not installed)"
fi
echo "  packages:"
if command -v dpkg &>/dev/null; then
    for pkg in xserver-xorg-input-wacom libwacom2 libwacom-common; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            ok "$pkg: installed"
        else
            info "$pkg: not installed"
        fi
    done
else
    info "dpkg not available — skipping package checks"
fi

echo ""
