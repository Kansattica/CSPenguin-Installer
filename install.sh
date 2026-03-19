#!/usr/bin/env bash
set -euo pipefail

VERBOSE=0
SKIP_WINETRICKS=0
for arg in "$@"; do
    [[ "$arg" == "--verbose"         || "$arg" == "-v" ]] && VERBOSE=1
    [[ "$arg" == "--skip-winetricks" || "$arg" == "-s" ]] && SKIP_WINETRICKS=1
done

DOWNLOAD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/csp-install"

# when run via bash <(curl ...), BASH_SOURCE[0] is a fd with no patches dir nearby
_candidate="$(cd "$(dirname "${BASH_SOURCE[0]:-/}")" 2>/dev/null && pwd)"
if [[ -d "$_candidate/patches" ]]; then
    SCRIPT_DIR="$_candidate"
else
    SCRIPT_DIR="$DOWNLOAD_DIR"
fi

WINEPREFIX="${WINEPREFIX:-$HOME/.wine-csp}"
WINEARCH=win64

WINE_VERSION="10.20"
WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-staging-amd64.tar.xz"
WEBVIEW2_URL="https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/76eb3dc4-7851-45b7-a392-460523b0e2bb/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
LAUNCHER_DIR="$HOME/.local/share/cspenguin"
WINE_DIR="$LAUNCHER_DIR/wine-${WINE_VERSION}"
WINE_BIN="$WINE_DIR/bin/wine"
WINESERVER_BIN="$WINE_DIR/bin/wineserver"
LAUNCH_SCRIPT="$LAUNCHER_DIR/csp-launch.sh"
LAUNCHER_STUDIO="$LAUNCHER_DIR/clipstudio-launch.sh"
CSP_INSTALL_PATH="$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5/CLIP STUDIO PAINT/CLIPStudioPaint.exe"
STUDIO_EXE="$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5/CLIP STUDIO/CLIPStudio.exe"
SYS32="$WINEPREFIX/drive_c/windows/system32"
LOG_FILE="/tmp/csp-install.log"

STEP=0
step()  { STEP=$((STEP + 1)); echo ""; echo "[$STEP] $1"; }
ok()    { echo "  + $1"; }
warn()  { echo "  ! $1"; }
die()   { echo ""; echo "  ERROR: $1"; echo "  log: $LOG_FILE"; exit 1; }

run() {
    if [[ $VERBOSE -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

GH_RAW="https://raw.githubusercontent.com/parka6060/CSPenguin-Installer/main"

fetch_asset() {
    local rel="$1" dest="$2"
    if [[ -f "$dest" && -s "$dest" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    echo "  ... fetching $rel"
    wget -q -O "$dest" "$GH_RAW/$rel" || die "failed to download $rel"
}

ensure_asset() {
    local rel="$1" dest="$2"
    if [[ ! -f "$dest" ]]; then
        fetch_asset "$rel" "$dest"
    fi
}

wait_for() {
    local msg="$1"; shift
    if [[ $VERBOSE -eq 1 ]]; then
        echo "  - $msg"
        run "$@" || die "$msg failed"
        echo "  + $msg"
        return
    fi
    local -a dots=('.' '..' '...')
    local i=0
    run "$@" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  - %s %s   " "$msg" "${dots[$((i % 3))]}"
        sleep 0.5
        i=$((i + 1))
    done
    wait "$pid" || die "$msg failed"
    printf "\r  + %s\n" "$msg"
}

_detect_pm() {
    command -v pacman >/dev/null 2>&1 && echo "pacman" && return
    command -v dnf    >/dev/null 2>&1 && echo "dnf"    && return
    command -v apt    >/dev/null 2>&1 && echo "apt"    && return
    echo "unknown"
}

_gst_ok() { command -v gst-inspect-1.0 >/dev/null 2>&1 && gst-inspect-1.0 h264parse >/dev/null 2>&1; }

_install_deps_pacman() {
    local pkgs=()
    command -v wine       >/dev/null 2>&1 || pkgs+=(wine)
    command -v winetricks >/dev/null 2>&1 || pkgs+=(winetricks)
    command -v wget       >/dev/null 2>&1 || pkgs+=(wget)
    _gst_ok                                || pkgs+=(gst-plugins-bad gst-plugins-good)
    [[ ${#pkgs[@]} -gt 0 ]] && sudo pacman -S --needed "${pkgs[@]}"
}

_install_deps_dnf() {
    local pkgs=()
    command -v wine       >/dev/null 2>&1 || pkgs+=(wine)
    command -v winetricks >/dev/null 2>&1 || pkgs+=(winetricks)
    command -v wget       >/dev/null 2>&1 || pkgs+=(wget)
    _gst_ok                                || pkgs+=(gstreamer1-plugins-bad-free gstreamer1-plugins-good)
    [[ ${#pkgs[@]} -gt 0 ]] && sudo dnf install -y "${pkgs[@]}"
}

_install_deps_apt() {
    local pkgs=(dirmngr ca-certificates)
    command -v winetricks >/dev/null 2>&1 || pkgs+=(winetricks)
    command -v wget       >/dev/null 2>&1 || pkgs+=(wget)
    _gst_ok                                || pkgs+=(gstreamer1.0-plugins-bad gstreamer1.0-plugins-good)
    sudo apt install -y "${pkgs[@]}"

    local need_wine=0
    if ! command -v wine >/dev/null 2>&1; then
        need_wine=1
    else
        local _v; _v=$(wine --version 2>/dev/null | grep -oP '\d+' | head -1)
        [[ "$_v" -ge 9 ]] || need_wine=1
    fi

    if [[ $need_wine -eq 1 ]]; then
        echo "  setting up WineHQ repository..."
        sudo mkdir -pm755 /etc/apt/keyrings
        wget -O - https://dl.winehq.org/wine-builds/winehq.key | \
            sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key -
        . /etc/os-release
        sudo dpkg --add-architecture i386
        sudo wget -NP /etc/apt/sources.list.d/ \
            "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_CODENAME:-$VERSION_CODENAME}/winehq-${UBUNTU_CODENAME:-$VERSION_CODENAME}.sources"
        sudo apt update
        sudo apt install -y --install-recommends winehq-staging
    fi
}

: > "$LOG_FILE"
echo "CSPenguin-Installer > $(date)" >> "$LOG_FILE"

cat << 'EOF'

    .--.
   |o_o |  CSPenguin-Installer!
   |:_/ |  Never stop drawing.
  //   \ \   
 (|     | ) <3 https://eninabox.art
/'\_   _/`\
\___)=(___/

EOF

echo "  Which version?"
echo "    1) 5.0.1 (latest)"
echo "    2) 4.1.0"
echo "    3) custom installer path or URL"
echo ""

CSP_VERSION="" CSP_URL="" CSP_EXE_NAME=""
while true; do
    read -rp "  choice [1]: " choice </dev/tty
    choice="${choice:-1}"
    case "$choice" in
        1) CSP_VERSION="501"; break ;;
        2) CSP_VERSION="410"; break ;;
        3)
            read -rp "  path or URL: " custom </dev/tty
            if [[ "$custom" == http* ]]; then
                CSP_URL="$custom"
                CSP_EXE_NAME="$(basename "$custom")"
                CSP_VERSION="custom"
            elif [[ -f "$custom" ]]; then
                CSP_EXE_NAME="$(basename "$custom")"
                mkdir -p "$DOWNLOAD_DIR"
                cp "$custom" "$DOWNLOAD_DIR/$CSP_EXE_NAME"
                CSP_URL=""
                CSP_VERSION="custom"
            else
                echo "  file not found: $custom"; continue
            fi
            break ;;
        *) echo "  pick 1, 2, or 3" ;;
    esac
done

if [[ "$CSP_VERSION" != "custom" ]]; then
    CSP_URL="https://vd.clipstudio.net/clipcontent/paint/app/${CSP_VERSION}/CSP_${CSP_VERSION}w_setup.exe"
    CSP_EXE_NAME="CSP_${CSP_VERSION}w_setup.exe"
fi

step "dependencies"

_missing=()
command -v winetricks >/dev/null 2>&1 || _missing+=(winetricks)
command -v wget       >/dev/null 2>&1 || _missing+=(wget)
_gst_ok                                || _missing+=("gstreamer plugins")

if [[ ${#_missing[@]} -gt 0 ]]; then
    echo "  missing: ${_missing[*]}"
    _pm="$(_detect_pm)"
    if [[ "$_pm" == "unknown" ]]; then
        die "unsupported distro > install winetricks, wget, and gstreamer plugins manually"
    fi
    read -rp "  install automatically? [Y/n]: " _ans </dev/tty
    if [[ "${_ans:-y}" =~ ^[Yy]$ ]]; then
        case "$_pm" in
            pacman) _install_deps_pacman ;;
            dnf)    _install_deps_dnf ;;
            apt)    _install_deps_apt ;;
        esac
    else
        die "install dependencies manually, then re-run"
    fi
fi

ok "winetricks"

step "downloads"
mkdir -p "$DOWNLOAD_DIR" "$LAUNCHER_DIR"

download() {
    local name="$1" url="$2" dest="$3"
    if [[ -f "$dest" ]] && [[ -s "$dest" ]]; then
        ok "$name (cached)"
        return
    fi
    echo "  - $name"
    wget -L -q --show-progress --timeout=30 --tries=3 -O "$dest" "$url" || die "$name download failed"
    printf "\r  + %s\n" "$name"
}

if [[ -n "${CSP_URL:-}" ]]; then
    download "Clip Studio Paint" "$CSP_URL" "$DOWNLOAD_DIR/$CSP_EXE_NAME"
else
    ok "Clip Studio Paint (local file)"
fi
_wine_tar="$DOWNLOAD_DIR/wine-${WINE_VERSION}-amd64.tar.xz"
if [[ ! -x "$WINE_BIN" ]]; then
    download "Wine ${WINE_VERSION}" "$WINE_URL" "$_wine_tar"
    echo "  - extracting Wine ${WINE_VERSION}..."
    mkdir -p "$LAUNCHER_DIR"
    tar -xf "$_wine_tar" -C "$LAUNCHER_DIR"
    for _d in "$LAUNCHER_DIR/wine-${WINE_VERSION}-staging-amd64" \
               "$LAUNCHER_DIR/wine-${WINE_VERSION}-amd64"; do
        [[ -d "$_d" ]] && mv "$_d" "$WINE_DIR" && break
    done
    [[ -x "$WINE_BIN" ]] || die "Wine ${WINE_VERSION} extraction failed"
fi
ok "Wine ${WINE_VERSION} ($WINE_BIN)"

download "WebView2 Runtime 135" "$WEBVIEW2_URL" "$DOWNLOAD_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"

# Use this Wine for all subsequent commands in the install script
export PATH="$WINE_DIR/bin:$PATH"

step "wine prefix"
export WINEPREFIX WINEARCH WINESERVER="$WINESERVER_BIN"
# kill any running wineserver (system or pre-warm); version mismatch will break init
"$WINESERVER_BIN" -k 2>/dev/null || true
wineserver -k 2>/dev/null || true
sleep 0.5
wait_for "initialising prefix" env WINEDEBUG=-all wineboot --init

step "runtime components"
if [[ $SKIP_WINETRICKS -eq 1 ]]; then
    ok "skipped (--skip-winetricks)"
else
    _wt_log="$WINEPREFIX/winetricks.log"
    _wt_needed=()
    for pkg in corefonts vcrun2022 dotnet48 dxvk vkd3d; do
        grep -qx "$pkg" "$_wt_log" 2>/dev/null || _wt_needed+=("$pkg")
    done
    if [[ ${#_wt_needed[@]} -eq 0 ]]; then
        ok "corefonts vcrun2022 dotnet48 dxvk vkd3d (already installed)"
    else
        [[ " ${_wt_needed[*]} " == *" dotnet48 "* ]] && warn "This step could take a while, pet a cat or something!"
        wait_for "${_wt_needed[*]}" env WINEDEBUG=-all winetricks -q "${_wt_needed[@]}"
    fi
fi

step "esync (open file limit)"

_nofile=$(ulimit -n 2>/dev/null || echo 0)
if [[ "$_nofile" -ge 524288 ]]; then
    ok "limit already sufficient ($_nofile)"
else
    _esync_set=0

    # systemd user config: no sudo needed
    if systemctl --user status >/dev/null 2>&1; then
        mkdir -p "$HOME/.config/systemd/user.conf.d"
        cat > "$HOME/.config/systemd/user.conf.d/cspenguin-limits.conf" << 'EOF'
[Manager]
DefaultLimitNOFILE=524288
EOF
        ok "set via systemd user config (takes effect on next login)"
        _esync_set=1
    fi

    # limits.d fallback for non-systemd sessions
    if sudo tee /etc/security/limits.d/cspenguin.conf > /dev/null << EOF
# CSPenguin-Installer : esync file descriptor limit
* soft nofile 524288
* hard nofile 524288
EOF
    then
        [[ $_esync_set -eq 0 ]] && ok "set via /etc/security/limits.d/cspenguin.conf"
        _esync_set=1
    fi

    if [[ $_esync_set -eq 0 ]]; then
        warn "could not set file limit, add to /etc/security/limits.conf manually:"
        warn "  * soft nofile 524288"
        warn "  * hard nofile 524288"
    else
        warn "log out and back in for esync to take effect"
    fi
fi

step "compatibility settings"

run wine reg add "HKCU\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
ok "windows version: win10"

run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "concrt140" /t REG_SZ /d "native,builtin" /f
ok "dll override: concrt140"

run wine reg add "HKCU\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f
ok "crash dialog suppressed"

cat > "$WINEPREFIX/dxvk.conf" << 'EOF'
dxgi.deferSurfaceCreation = True
EOF
ok "dxvk.conf"

step "patches"

mkdir -p "$LAUNCHER_DIR"

DCOMP_DLL="$SCRIPT_DIR/patches/dcomp/dcomp.dll"
DCOMP_SRC="$SCRIPT_DIR/patches/dcomp/dcomp_csp.cpp"
DCOMP_DEF="$SCRIPT_DIR/patches/dcomp/dcomp.def"

PTHREAD_DLL="$SCRIPT_DIR/patches/dcomp/libwinpthread-1.dll"

ensure_asset "patches/dcomp/dcomp.dll"          "$DCOMP_DLL"
ensure_asset "patches/dcomp/libwinpthread-1.dll" "$PTHREAD_DLL"

if command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1 && [[ -f "$DCOMP_SRC" ]]; then
    wait_for "building dcomp.dll from source" x86_64-w64-mingw32-g++ -std=c++17 -O2 -shared \
        -static-libgcc -static-libstdc++ \
        -o "$DCOMP_DLL" "$DCOMP_SRC" "$DCOMP_DEF" \
        -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid
else
    ok "dcomp.dll (prebuilt)"
fi
[[ -f "$DCOMP_DLL" ]] || die "dcomp.dll not found - download failed or build error"

cp "$DCOMP_DLL"    "$LAUNCHER_DIR/dcomp.dll"
cp "$DCOMP_DLL"    "$SYS32/dcomp.dll"
cp "$PTHREAD_DLL"  "$SYS32/libwinpthread-1.dll"
run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dcomp" /t REG_SZ /d "native,builtin" /f
ok "dcomp.dll (WebView2 login/license panels)"

PATCHES_WIN="$SCRIPT_DIR/patches/x86_64-windows"
PATCHES_UNIX="$SCRIPT_DIR/patches/x86_64-unix"

ensure_asset "patches/x86_64-windows/mfplat.dll" "$PATCHES_WIN/mfplat.dll"
ensure_asset "patches/x86_64-windows/mfreadwrite.dll" "$PATCHES_WIN/mfreadwrite.dll"
ensure_asset "patches/x86_64-windows/winegstreamer.dll" "$PATCHES_WIN/winegstreamer.dll"
ensure_asset "patches/x86_64-unix/winegstreamer.so" "$PATCHES_UNIX/winegstreamer.so"

WINE_WIN="$WINE_DIR/lib/wine/x86_64-windows"
[[ -d "$WINE_WIN" ]] || WINE_WIN="$WINE_DIR/lib64/wine/x86_64-windows"
WINE_UNIX="$WINE_DIR/lib/wine/x86_64-unix"
[[ -d "$WINE_UNIX" ]] || WINE_UNIX="$WINE_DIR/lib64/wine/x86_64-unix"

if [[ -d "$PATCHES_WIN" ]] && [[ -d "$WINE_WIN" ]]; then
    for dll in mfplat.dll mfreadwrite.dll winegstreamer.dll; do
        [[ -f "$PATCHES_WIN/$dll" ]] && cp "$PATCHES_WIN/$dll" "$WINE_WIN/$dll" && cp "$PATCHES_WIN/$dll" "$SYS32/$dll"
    done
    ok "mfplat + mfreadwrite + winegstreamer (timelapse/video export)"
fi

if [[ -d "$PATCHES_UNIX" ]] && [[ -d "$WINE_UNIX" ]] && [[ -f "$PATCHES_UNIX/winegstreamer.so" ]]; then
    cp "$PATCHES_UNIX/winegstreamer.so" "$WINE_UNIX/winegstreamer.so"
    ok "winegstreamer.so (unix side)"
fi

run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "mfplat" /t REG_SZ /d "native,builtin" /f
run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "mfreadwrite" /t REG_SZ /d "native,builtin" /f

step "WebView2 + Clip Studio Paint"

# Install WebView2 Runtime standalone (no Edge browser needed; Edge would upgrade to 146+)
warn "WebView2 installer will open and close on its own, this is expected"
env WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
    wine "$DOWNLOAD_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" >> "$LOG_FILE" 2>&1 &
wait $! || true
env WINEDEBUG=-all wineserver -k 2>/dev/null || true
sleep 1
ok "WebView2 Runtime 135.0.3179.85"


echo ""
echo "  The CSP installer will open now."
echo "  Go through it normally, then come back here."
echo ""
read -rp "  press enter to continue..." </dev/tty
echo "  - waiting for installer to finish..."
env WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
    wine "$DOWNLOAD_DIR/$CSP_EXE_NAME" >> "$LOG_FILE" 2>&1 &
wait $! || die "CSP installer failed"
ok "Clip Studio Paint"

run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe" /v Version /t REG_SZ /d "win7" /f
run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\CLIPStudioPaint.exe" /v Version /t REG_SZ /d "win81" /f
run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\CLIPStudio.exe" /v Version /t REG_SZ /d "win81" /f

step "launch scripts + desktop entries"

cat > "$LAUNCH_SCRIPT" << LAUNCHEOF
#!/usr/bin/env bash
export PATH="$WINE_DIR/bin:\$PATH"
export WINESERVER="$WINESERVER_BIN"
export WINEPREFIX="$WINEPREFIX"
export WINEDEBUG=-all
export WINEESYNC=1
export WINEFSYNC=1
export WINEDLLPATH="$LAUNCHER_DIR:\${WINEDLLPATH:-}"
export DXVK_ASYNC=1
export DXVK_CONFIG_FILE="$WINEPREFIX/dxvk.conf"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox"
CSP_EXE="$CSP_INSTALL_PATH"
if [[ -n "\$1" ]] && command -v winepath &>/dev/null; then
    WIN_PATH="\$(WINEPREFIX="$WINEPREFIX" winepath --windows "\$1")"
    exec wine "\$CSP_EXE" "\$WIN_PATH"
else
    exec wine "\$CSP_EXE"
fi
LAUNCHEOF
chmod +x "$LAUNCH_SCRIPT"
ok "csp-launch.sh"

cat > "$LAUNCHER_STUDIO" << LAUNCHEOF
#!/usr/bin/env bash
export PATH="$WINE_DIR/bin:\$PATH"
export WINESERVER="$WINESERVER_BIN"
export WINEPREFIX="$WINEPREFIX"
export WINEDEBUG=-all
export WINEESYNC=1
export WINEFSYNC=1
export WINEDLLPATH="$LAUNCHER_DIR:\${WINEDLLPATH:-}"
export DXVK_ASYNC=1
export DXVK_CONFIG_FILE="$WINEPREFIX/dxvk.conf"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu-compositing --disable-gpu-vsync --in-process-gpu"
exec wine "$STUDIO_EXE"
LAUNCHEOF
chmod +x "$LAUNCHER_STUDIO"
ok "clipstudio-launch.sh"

DESKTOP_FILE="$HOME/.local/share/applications/clipstudiopaint.desktop"
DESKTOP_STUDIO="$HOME/.local/share/applications/clipstudio.desktop"

cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=Clip Studio Paint
Exec=$LAUNCH_SCRIPT %f
Terminal=false
Type=Application
Categories=Graphics;
MimeType=application/x-clip;
StartupWMClass=clipstudiopaint.exe
EOF

cat > "$DESKTOP_STUDIO" << EOF
[Desktop Entry]
Name=CLIP STUDIO
Exec=$LAUNCHER_STUDIO
Terminal=false
Type=Application
Categories=Graphics;
StartupWMClass=clipstudio.exe
EOF

chmod +x "$DESKTOP_FILE" "$DESKTOP_STUDIO"
ok "desktop entries"

if [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]]; then
    cp "$DESKTOP_FILE"   "$HOME/Desktop/clipstudiopaint.desktop" 2>/dev/null || true
    cp "$DESKTOP_STUDIO" "$HOME/Desktop/clipstudio.desktop"      2>/dev/null || true
    ok "KDE desktop shortcuts"

    # KDE window rules: wine menus/popups z-order fix
    _kwinrc="$HOME/.config/kwinrulesrc"
    _kwc="" _krc=""
    if command -v kwriteconfig6 >/dev/null 2>&1; then
        _kwc=kwriteconfig6; _krc=kreadconfig6
    elif command -v kwriteconfig5 >/dev/null 2>&1; then
        _kwc=kwriteconfig5; _krc=kreadconfig5
    fi

    if [[ -n "$_kwc" ]]; then
        # Check if our rules already exist
        if ! grep -q "CSPenguin:" "$_kwinrc" 2>/dev/null; then
            _uuid_below="cspenguin-$(uuidgen 2>/dev/null || echo below-rule)"
            _uuid_ghost="cspenguin-$(uuidgen 2>/dev/null || echo ghost-rule)"

            # Rule 1: keep CSP main window below so menus/popups render above it
            $_kwc --file kwinrulesrc --group "$_uuid_below" --key Description "CSPenguin: CSP below for popups"
            $_kwc --file kwinrulesrc --group "$_uuid_below" --key below true
            $_kwc --file kwinrulesrc --group "$_uuid_below" --key belowrule 3
            $_kwc --file kwinrulesrc --group "$_uuid_below" --key wmclass "clipstudiopaint.exe"
            $_kwc --file kwinrulesrc --group "$_uuid_below" --key wmclassmatch 2

            # Rule 2: hide wine ghost dialog windows from taskbar/pager
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key Description "CSPenguin: Hide Wine ghost windows"
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key wmclass "clipstudiopaint.exe"
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key wmclassmatch 2
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key types 32
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skipswitcher true
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skipswitcherrule 3
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skiptaskbar true
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skiptaskbarrule 3
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skippager true
            $_kwc --file kwinrulesrc --group "$_uuid_ghost" --key skippagerrule 3

            # Update General section
            _existing_rules=$($_krc --file kwinrulesrc --group General --key rules 2>/dev/null || true)
            _existing_count=$($_krc --file kwinrulesrc --group General --key count 2>/dev/null || echo 0)
            _new_count=$((_existing_count + 2))
            if [[ -n "$_existing_rules" ]]; then
                _new_rules="${_existing_rules},${_uuid_below},${_uuid_ghost}"
            else
                _new_rules="${_uuid_below},${_uuid_ghost}"
            fi
            $_kwc --file kwinrulesrc --group General --key count "$_new_count"
            $_kwc --file kwinrulesrc --group General --key rules "$_new_rules"

            # Reload KWin rules
            qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || \
                dbus-send --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
            ok "KDE window rules (popups + ghost windows)"
        else
            ok "KDE window rules (already set)"
        fi
    else
        warn "kwriteconfig not found, skipping KDE window rules"
        warn "set CSP window rule manually: System Settings > Window Management > Window Rules"
    fi
fi

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

step "wineserver pre-warm (faster startup)"

echo ""
echo "  Pre-warming the wineserver at login reduces CSP startup time by ~5-10s."
echo "  This runs a tiny background process on login (uses ~2MB RAM)."
echo ""
read -rp "  Enable wineserver pre-warm? [Y/n] " _prewarm </dev/tty
if [[ "${_prewarm,,}" != "n" ]]; then
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/csp-wineserver.service" << EOF
[Unit]
Description=Wine server pre-warm for CSP
After=default.target

[Service]
Type=simple
Environment=WINEPREFIX=$WINEPREFIX
Environment=WINESERVER=$WINESERVER_BIN
Environment=WINEDEBUG=-all
ExecStartPre=-$WINESERVER_BIN -k
ExecStart=$WINESERVER_BIN -f
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
EOF
    if systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now csp-wineserver.service 2>/dev/null; then
        ok "wineserver service enabled"
    else
        warn "could not enable wineserver service (non-systemd session)"
    fi
else
    ok "skipped"
fi

step "thumbnails (.clip file previews)"

THUMBNAILER_SRC="$SCRIPT_DIR/patches/thumbnailer/clip-thumbnailer"
THUMBNAILER_BIN="$HOME/.local/bin/clip-thumbnailer"

ensure_asset "patches/thumbnailer/clip-thumbnailer" "$THUMBNAILER_SRC"

mkdir -p "$HOME/.local/bin"
if [[ -x "$THUMBNAILER_BIN" ]]; then
    ok "clip-thumbnailer (already installed)"
else
    install -Dm755 "$THUMBNAILER_SRC" "$THUMBNAILER_BIN"
    ok "clip-thumbnailer"
fi

# mime type
_MIME_DIR="$HOME/.local/share/mime"
mkdir -p "$_MIME_DIR/packages"
if [[ ! -f "$_MIME_DIR/packages/clip.xml" ]]; then
    cat > "$_MIME_DIR/packages/clip.xml" << 'MIMEEOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-clip">
    <comment>Clip Studio Paint file</comment>
    <glob pattern="*.clip"/>
  </mime-type>
</mime-info>
MIMEEOF
    update-mime-database "$_MIME_DIR" 2>/dev/null || true
    ok "MIME type (application/x-clip)"
else
    ok "MIME type (already registered)"
fi

# thumbnailer entry
_THUMB_DIR="$HOME/.local/share/thumbnailers"
mkdir -p "$_THUMB_DIR"
if [[ ! -f "$_THUMB_DIR/clip.thumbnailer" ]]; then
    cat > "$_THUMB_DIR/clip.thumbnailer" << THUMBEOF
[Thumbnailer Entry]
TryExec=$THUMBNAILER_BIN
Exec=$THUMBNAILER_BIN %i %o
MimeType=application/x-clip;
THUMBEOF
    ok "thumbnailer entry"
else
    ok "thumbnailer entry (already registered)"
fi

echo ""
echo "  done. run Clip Studio Paint from your app launcher or:"
echo "  $LAUNCH_SCRIPT"
echo ""
echo "  tips:"
echo "    pen pressure  File > Preferences > Tablet > Use mouse mode"
echo "    hidpi         WINEPREFIX=\"$WINEPREFIX\" winecfg > Graphics > DPI"
echo "    launch speed  restart your computer to ensure esync is active"
echo ""
