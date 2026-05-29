#!/usr/bin/env bash
#
# tiny11coremaker.sh — POSIX/Linux port of tiny11Coremaker.ps1
#
# Builds a significantly reduced ("Core") Windows 11 ISO from an official
# Windows 11 ISO, entirely with Linux tools — no Windows, no DISM, no Wine.
#
# Original project (PowerShell, Windows-only):
#   https://github.com/ntdevlabs/tiny11builder  (author: NTDEV / ntdevlabs)
# This is an independent, from-scratch reimplementation that reproduces the
# behaviour of tiny11Coremaker.ps1. All credit for the design and the choice
# of what to strip belongs to the original authors.
#
# Tooling map (Windows -> Linux):
#   DISM mount/commit/export ........ wimlib-imagex (wimtools)
#   reg.exe load/add/delete ......... hivexregedit (libwin-hivex-perl)
#   takeown / icacls ................ not needed (we own the FUSE mount)
#   oscdimg.exe ..................... xorriso
#   ISO mount + copy ................ 7z (p7zip-full)
#
# WARNING: the Core image is NOT serviceable. You cannot add languages,
# updates, or features after creation. Intended for disposable / template
# VMs (e.g. Proxmox). See README for the full list of limitations.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration / arguments
# ---------------------------------------------------------------------------
ISO=""
SCRATCH=""
OUTPUT=""
INDEX=""
LANG_CODE=""
ASSUME_YES=0
KEEP_SCRATCH=0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
tiny11coremaker.sh — build a Core (ultra-minimal) Windows 11 ISO on Linux.

Usage:
  tiny11coremaker.sh --iso <path-to-windows11.iso> [options]

Options:
  --iso PATH        Source Windows 11 ISO (required).
  --scratch DIR     Working directory (default: a fresh mktemp dir).
                    Needs ~15-20 GB free.
  --output FILE     Output ISO path (default: ./tiny11core.iso).
  --index N         Image index to use (skips the interactive prompt).
  --lang CODE       UI language code override, e.g. en-US (default: autodetect).
  -y, --yes         Assume "yes" to confirmation prompts (non-interactive).
  --keep            Do not delete the scratch directory on exit.
  -h, --help        Show this help.

Dependencies: wimtools, libwin-hivex-perl, libhivex-bin, p7zip-full, xorriso.
  Debian/Ubuntu: sudo apt install wimtools libwin-hivex-perl libhivex-bin p7zip-full xorriso
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)     ISO="$2"; shift 2 ;;
        --scratch) SCRATCH="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --index)   INDEX="$2"; shift 2 ;;
        --lang)    LANG_CODE="$2"; shift 2 ;;
        -y|--yes)  ASSUME_YES=1; shift ;;
        --keep)    KEEP_SCRATCH=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Find a file/dir under $1 matching case-insensitive name $2 (depth 1).
find_ci() { find "$1" -maxdepth 1 -iname "$2" 2>/dev/null | head -n1; }

SEVENZIP=""
pick_7z() {
    for c in 7zz 7z 7za; do command -v "$c" >/dev/null 2>&1 && { SEVENZIP="$c"; return; }; done
    die "7z not found (install p7zip-full)."
}

MOUNTED=""
cleanup() {
    set +e
    if [[ -n "$MOUNTED" ]] && mountpoint -q "$MOUNTED" 2>/dev/null; then
        log "Cleaning up: unmounting WIM (discarding) ..."
        wimlib-imagex unmount "$MOUNTED" >/dev/null 2>&1
    fi
    if [[ "$KEEP_SCRATCH" -eq 0 && -n "${SCRATCH:-}" && -d "$SCRATCH" && "${SCRATCH_OWNED:-0}" -eq 1 ]]; then
        log "Cleaning up scratch dir $SCRATCH ..."
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT INT TERM

# Merge a regedit-format .reg file (read from stdin) into a hive.
#   merge_reg <hive-file> <prefix>
#
# hivexregedit's --merge only creates a key if its IMMEDIATE parent already
# exists (unlike reg.exe, which creates the whole path). So we first expand
# every "[create]" block into its ancestor chain (shallow -> deep), emitting
# each missing ancestor as its own empty create block. Re-declaring an
# existing key is harmless (its values are preserved). Delete blocks ("[-...]")
# are passed through untouched.
merge_reg() {
    local hive="$1" prefix="$2" tmp
    tmp="$(mktemp)"
    awk -v prefix="$prefix" '
        function emit_ancestors(key,   rest, n, parts, i, acc) {
            rest = substr(key, length(prefix) + 1)
            sub(/^\\/, "", rest)
            n = split(rest, parts, "\\")
            acc = prefix
            for (i = 1; i < n; i++) {
                acc = acc "\\" parts[i]
                print "[" acc "]"
                print ""
            }
        }
        /^\[-/ { print; next }                       # delete node: pass through
        /^\[/  {                                      # create node: expand parents
            key = substr($0, 2, length($0) - 2)
            emit_ancestors(key)
            print
            next
        }
        { print }                                    # values, blanks, header
    ' > "$tmp"
    hivexregedit --merge --prefix "$prefix" "$hive" "$tmp" \
        || die "hivexregedit merge failed for $hive (prefix $prefix)"
    rm -f "$tmp"
}

# Locate the registry hive files inside the mounted image (case-insensitive).
declare -A HIVE
locate_hives() {
    local cfg; cfg="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname config -type d | head -n1)"
    [[ -d "$cfg" ]] || die "Could not find Windows\\System32\\config in image."
    HIVE[SOFTWARE]="$(find "$cfg" -maxdepth 1 -iname SOFTWARE | head -n1)"
    HIVE[SYSTEM]="$(find "$cfg"   -maxdepth 1 -iname SYSTEM   | head -n1)"
    HIVE[DEFAULT]="$(find "$cfg"  -maxdepth 1 -iname default  | head -n1)"
    local usersdef; usersdef="$(find "$MOUNT" -maxdepth 1 -iname Users -type d | head -n1)/Default"
    HIVE[NTUSER]="$(find "$usersdef" -maxdepth 1 -iname ntuser.dat 2>/dev/null | head -n1)"
    [[ -f "${HIVE[SOFTWARE]:-}" ]] || die "SOFTWARE hive not found."
    [[ -f "${HIVE[SYSTEM]:-}"   ]] || die "SYSTEM hive not found."
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -n "$ISO" ]]      || { usage; die "--iso is required."; }
[[ -f "$ISO" ]]      || die "ISO not found: $ISO"
ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"   # absolutize

missing=()
for t in wimlib-imagex hivexregedit hivexget xorriso; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
pick_7z
if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing tools: ${missing[*]}
Install with: sudo apt install wimtools libwin-hivex-perl libhivex-bin p7zip-full xorriso"
fi

cat <<'BANNER'
============================================================
  tiny11 Core builder — POSIX/Linux port
------------------------------------------------------------
  This generates a SIGNIFICANTLY reduced Windows 11 image.
  It is NOT serviceable: you cannot add languages, updates,
  or features afterwards. Best for disposable / template VMs.
============================================================
BANNER
if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Do you want to continue? (y/N) " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }
fi

# Scratch dir
SCRATCH_OWNED=0
if [[ -z "$SCRATCH" ]]; then
    SCRATCH="$(mktemp -d -t tiny11core.XXXXXX)"; SCRATCH_OWNED=1
else
    mkdir -p "$SCRATCH"
fi
SCRATCH="$(cd "$SCRATCH" && pwd)"
BUILD="$SCRATCH/tiny11"            # extracted ISO tree   (analog of C:\tiny11)
MOUNT="$SCRATCH/scratchdir"        # WIM mount point      (analog of C:\scratchdir)
SOURCES="$BUILD/sources"
[[ -z "$OUTPUT" ]] && OUTPUT="$(pwd)/tiny11core.iso"
mkdir -p "$BUILD" "$MOUNT"

log "Scratch:  $SCRATCH"
log "Output:   $OUTPUT"

# ---------------------------------------------------------------------------
# 1. Extract the source ISO
# ---------------------------------------------------------------------------
log "Extracting source ISO (this can take a few minutes) ..."
"$SEVENZIP" x -y -o"$BUILD" "$ISO" >/dev/null
chmod -R u+w "$BUILD"
[[ -d "$SOURCES" ]] || { SOURCES="$(find_ci "$BUILD" sources)"; }
[[ -d "$SOURCES" ]] || die "No 'sources' directory in the ISO — is this a Windows 11 ISO?"

INSTALL_WIM="$(find_ci "$SOURCES" install.wim || true)"
INSTALL_ESD="$(find_ci "$SOURCES" install.esd || true)"
BOOT_WIM="$(find_ci "$SOURCES" boot.wim || true)"
[[ -f "$BOOT_WIM" ]] || die "sources/boot.wim missing."

# ---------------------------------------------------------------------------
# 2. install.esd -> install.wim conversion (if needed)
# ---------------------------------------------------------------------------
if [[ ! -f "$INSTALL_WIM" ]]; then
    [[ -f "$INSTALL_ESD" ]] || die "Neither install.wim nor install.esd found in sources."
    log "Found install.esd. Available editions:"
    wimlib-imagex info "$INSTALL_ESD" | grep -E '^(Index|Name|Description)' || true
    if [[ -z "$INDEX" ]]; then
        read -r -p "Enter the image index to convert: " INDEX
    fi
    log "Converting install.esd -> install.wim (index $INDEX, LZX). This may take a while ..."
    INSTALL_WIM="$SOURCES/install.wim"
    wimlib-imagex export "$INSTALL_ESD" "$INDEX" "$INSTALL_WIM" --compress=LZX --check
fi
# Core ships install.esd, not install.wim: drop any stray esd from the tree.
[[ -n "$INSTALL_ESD" && -f "$INSTALL_ESD" ]] && rm -f "$INSTALL_ESD"

# ---------------------------------------------------------------------------
# 3. Choose index, detect architecture + language
# ---------------------------------------------------------------------------
log "Image information:"
wimlib-imagex info "$INSTALL_WIM" | grep -E '^(Index|Name|Description|Architecture)' || true
if [[ -z "$INDEX" ]]; then
    read -r -p "Enter the image index to build from: " INDEX
fi

info="$(wimlib-imagex info "$INSTALL_WIM" "$INDEX")"
arch_raw="$(printf '%s\n' "$info" | sed -n 's/^Architecture[[:space:]]*[:=][[:space:]]*//p' | head -n1)"
case "${arch_raw,,}" in
    *aarch64*|*arm64*) ARCH="arm64" ;;
    *x86_64*|*amd64*|*x64*) ARCH="amd64" ;;
    *x86*|*i386*) ARCH="x86" ;;
    *) ARCH="amd64"; warn "Unknown architecture '$arch_raw'; assuming amd64." ;;
esac
log "Architecture: $ARCH"

if [[ -z "$LANG_CODE" ]]; then
    LANG_CODE="$(printf '%s\n' "$info" | sed -n 's/^Default Language[[:space:]]*[:=][[:space:]]*//p' | head -n1)"
    [[ -z "$LANG_CODE" ]] && LANG_CODE="$(printf '%s\n' "$info" | sed -n 's/^Languages[[:space:]]*[:=][[:space:]]*//p' | head -n1 | awk '{print $1}')"
    [[ -z "$LANG_CODE" ]] && LANG_CODE="en-US"
fi
log "UI language: $LANG_CODE"

# ---------------------------------------------------------------------------
# 4. Mount install.wim read-write
# ---------------------------------------------------------------------------
log "Mounting install image (index $INDEX) ..."
wimlib-imagex mountrw "$INSTALL_WIM" "$INDEX" "$MOUNT"
MOUNTED="$MOUNT"

# ---------------------------------------------------------------------------
# 5. Remove provisioned Appx packages
#    (delete staged payload + record names for registry de-provisioning)
# ---------------------------------------------------------------------------
log "Removing provisioned apps ..."
PKG_PREFIXES=(
    'Clipchamp.Clipchamp_' 'Microsoft.BingNews_' 'Microsoft.BingWeather_'
    'Microsoft.GamingApp_' 'Microsoft.GetHelp_' 'Microsoft.Getstarted_'
    'Microsoft.MicrosoftOfficeHub_' 'Microsoft.MicrosoftSolitaireCollection_'
    'Microsoft.People_' 'Microsoft.PowerAutomateDesktop_' 'Microsoft.Todos_'
    'Microsoft.WindowsAlarms_' 'microsoft.windowscommunicationsapps_'
    'Microsoft.WindowsFeedbackHub_' 'Microsoft.WindowsMaps_'
    'Microsoft.WindowsSoundRecorder_' 'Microsoft.Xbox.TCUI_'
    'Microsoft.XboxGamingOverlay_' 'Microsoft.XboxGameOverlay_'
    'Microsoft.XboxSpeechToTextOverlay_' 'Microsoft.YourPhone_'
    'Microsoft.ZuneMusic_' 'Microsoft.ZuneVideo_'
    'MicrosoftCorporationII.MicrosoftFamily_' 'MicrosoftCorporationII.QuickAssist_'
    'MicrosoftTeams_' 'Microsoft.549981C3F5F10_' 'Microsoft.Windows.Copilot'
    'MSTeams_' 'Microsoft.OutlookForWindows_' 'Microsoft.Windows.Teams_'
    'Microsoft.Copilot_'
)
WINAPPS="$(find "$MOUNT" -maxdepth 2 -ipath '*/Program Files/WindowsApps' -type d | head -n1)"
APPREPO="$(find "$MOUNT" -maxdepth 5 -ipath '*/AppRepository/Packages' -type d | head -n1)"
REMOVED_FULLNAMES=()
if [[ -d "$WINAPPS" ]]; then
    for prefix in "${PKG_PREFIXES[@]}"; do
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            name="$(basename "$d")"
            echo "  - $name"
            REMOVED_FULLNAMES+=("$name")
            rm -rf "$d"
            # matching AppRepository staging, if present
            if [[ -d "$APPREPO" ]]; then
                find "$APPREPO" -maxdepth 1 -name "$name" -exec rm -rf {} + 2>/dev/null || true
            fi
        done < <(find "$WINAPPS" -maxdepth 1 -type d -iname "${prefix}*" 2>/dev/null)
    done
else
    warn "WindowsApps folder not found; skipping payload deletion."
fi

# ---------------------------------------------------------------------------
# 6. Approximate offline removal of optional system components
#    (DISM /Remove-Package has no Linux equivalent; we delete the isolated
#     payloads we safely can. Defender/IE servicing state is handled via the
#     registry below, and WinSxS reduction removes most backing components.)
# ---------------------------------------------------------------------------
log "Removing optional component payloads (best effort) ..."
rm_path() { local p; p="$(find "$MOUNT" -maxdepth 6 -ipath "$MOUNT/$1" 2>/dev/null | head -n1)"; [[ -n "$p" ]] && rm -rf "$p" && echo "  - ${1}"; true; }
rm_path 'Program Files/Internet Explorer'
rm_path 'Program Files (x86)/Internet Explorer'
rm_path 'Program Files/Windows Media Player'
rm_path 'Program Files (x86)/Windows Media Player'
rm_path 'Windows/System32/psr.exe'                                   # Steps Recorder
rm_path 'Program Files/Windows NT/Accessories/wordpad.exe'           # WordPad
rm_path 'Program Files/Windows NT/Accessories/write.exe'
rm_path 'Program Files/Common Files/microsoft shared/ink/mip.exe'    # Tablet PC Math

# ---------------------------------------------------------------------------
# 7. Remove Edge, OneDrive, WinRE
# ---------------------------------------------------------------------------
log "Removing Edge ..."
for sub in "Edge" "EdgeUpdate" "EdgeCore"; do
    p="$(find "$MOUNT" -maxdepth 5 -ipath "*/Program Files (x86)/Microsoft/$sub" -type d | head -n1)"
    [[ -n "$p" ]] && rm -rf "$p"
done
# Edge WebView component in WinSxS (architecture-specific)
while IFS= read -r d; do [[ -n "$d" ]] && rm -rf "$d"; done < <(
    find "$MOUNT/Windows/WinSxS" -maxdepth 1 -type d -iname "${ARCH}_microsoft-edge-webview_31bf3856ad364e35*" 2>/dev/null)
p="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname "Microsoft-Edge-Webview" -type d | head -n1)"
[[ -n "$p" ]] && rm -rf "$p"

log "Removing WinRE ..."
recdir="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Recovery -type d | head -n1)"
if [[ -n "$recdir" ]]; then
    winre="$(find "$recdir" -maxdepth 1 -iname winre.wim | head -n1)"
    [[ -n "$winre" ]] && rm -f "$winre"
    : > "$recdir/winre.wim"      # empty placeholder, as the original does
fi

log "Removing OneDrive setup ..."
od="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname OneDriveSetup.exe | head -n1)"
if [[ -n "$od" ]]; then rm -f "$od"; else warn "OneDriveSetup.exe not present (expected on arm64)."; fi

# ---------------------------------------------------------------------------
# 8. WinSxS reduction (the big space win)
# ---------------------------------------------------------------------------
log "Reducing WinSxS (this can take a while) ..."
WINSXS="$MOUNT/Windows/WinSxS"
WINSXS_EDIT="$MOUNT/Windows/WinSxS_edit"
if [[ -d "$WINSXS" ]]; then
    mkdir -p "$WINSXS_EDIT"
    if [[ "$ARCH" == "amd64" ]]; then
        KEEP=(
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*"
            "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*"
            "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*"
            "x86_microsoft-windows-servicingstack-inetsrv_*"
            "x86_microsoft-windows-servicingstack-onecore_*"
            "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*"
            "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*"
            "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*"
            "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*"
            "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*"
            "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
            "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*"
            "Catalogs" "FileMaps" "Fusion" "InstallTemp" "Manifests"
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        )
    elif [[ "$ARCH" == "arm64" ]]; then
        KEEP=(
            "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*"
            "Catalogs" "FileMaps" "Fusion" "InstallTemp" "Manifests"
            "SettingsManifests" "Temp"
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "arm_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
            "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
            "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
            "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*"
            "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*"
            "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
            "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
            "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*"
            "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
        )
    else
        KEEP=("Catalogs" "FileMaps" "Fusion" "InstallTemp" "Manifests")
        warn "WinSxS keep-list not defined for $ARCH; keeping only base dirs."
    fi
    for pat in "${KEEP[@]}"; do
        while IFS= read -r src; do
            [[ -z "$src" ]] && continue
            cp -a "$src" "$WINSXS_EDIT/" 2>/dev/null || true
        done < <(find "$WINSXS" -maxdepth 1 -iname "$pat" 2>/dev/null)
    done
    log "Deleting original WinSxS ..."
    rm -rf "$WINSXS"
    mv "$WINSXS_EDIT" "$WINSXS"
else
    warn "WinSxS not found; skipping reduction."
fi

# ---------------------------------------------------------------------------
# 9. Registry tweaks on the install image
# ---------------------------------------------------------------------------
log "Applying registry tweaks (install image) ..."
locate_hives

# --- SYSTEM hive ---
merge_reg "${HIVE[SYSTEM]}" 'HKEY_LOCAL_MACHINE\SYSTEM' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassCPUCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
"BypassTPMCheck"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\BitLocker]
"PreventDeviceEncryption"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\dmwappushservice]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\wuauserv]
"Start"=dword:00000004

[-HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\WaaSMedicSVC]

[-HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\UsoSvc]

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\WinDefend]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\WdNisSvc]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\WdNisDrv]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\WdFilter]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\Sense]
"Start"=dword:00000004
REG

# --- DEFAULT hive ---
merge_reg "${HIVE[DEFAULT]}" 'HKEY_USERS\.DEFAULT' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_USERS\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache]
"SV1"=dword:00000000
"SV2"=dword:00000000
REG

# --- NTUSER hive (Default user profile) ---
merge_reg "${HIVE[NTUSER]}" 'HKEY_CURRENT_USER' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Control Panel\UnsupportedHardwareNotificationCache]
"SV1"=dword:00000000
"SV2"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"OemPreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEnabled"=dword:00000000
"SilentInstalledAppsEnabled"=dword:00000000
"ContentDeliveryAllowed"=dword:00000000
"FeatureManagementEnabled"=dword:00000000
"PreInstalledAppsEverEnabled"=dword:00000000
"SoftLandingEnabled"=dword:00000000
"SubscribedContentEnabled"=dword:00000000
"SubscribedContent-310093Enabled"=dword:00000000
"SubscribedContent-338388Enabled"=dword:00000000
"SubscribedContent-338389Enabled"=dword:00000000
"SubscribedContent-338393Enabled"=dword:00000000
"SubscribedContent-353694Enabled"=dword:00000000
"SubscribedContent-353696Enabled"=dword:00000000
"SystemPaneSuggestionsEnabled"=dword:00000000

[-HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions]

[-HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps]

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarMn"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo]
"Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Privacy]
"TailoredExperiencesWithDiagnosticDataEnabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy]
"HasAccepted"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Input\TIPC]
"Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization]
"RestrictImplicitInkCollection"=dword:00000001
"RestrictImplicitTextCollection"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization\TrainedDataStore]
"HarvestContacts"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Personalization\Settings]
"AcceptedPrivacyPolicy"=dword:00000000
REG

# --- SOFTWARE hive ---
# Note: backslashes inside REG_SZ values are doubled (\\) per .reg syntax.
merge_reg "${HIVE[SOFTWARE]}" 'HKEY_LOCAL_MACHINE\SOFTWARE' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent]
"DisableWindowsConsumerFeatures"=dword:00000001
"DisableConsumerAccountStateContent"=dword:00000001
"DisableCloudOptimizedContent"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Start]
"ConfigureStartPins"="{\"pinnedList\": [{}]}"

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\PushToInstall]
"DisablePushToInstall"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\MRT]
"DontOfferThroughWUAU"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE]
"BypassNRO"=dword:00000001
"DisableOnline"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager]
"ShippedWithReserves"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Chat]
"ChatIcon"=dword:00000003

[-HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge]

[-HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update]

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OneDrive]
"DisableFileSyncNGSC"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DataCollection]
"AllowTelemetry"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate]
"workCompleted"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate]
"workCompleted"=dword:00000001

[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate]

[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate]

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge]
"HubsSidebarEnabled"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Teams]
"DisableInstallation"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Mail]
"PreventRun"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"StopWUPostOOBE1"="net stop wuauserv"
"StopWUPostOOBE2"="sc stop wuauserv"
"StopWUPostOOBE3"="sc config wuauserv start= disabled"
"DisbaleWUPostOOBE1"="reg add HKLM\\SYSTEM\\CurrentControlSet\\Services\\wuauserv /v Start /t REG_DWORD /d 4 /f"
"DisbaleWUPostOOBE2"="reg add HKLM\\SYSTEM\\ControlSet001\\Services\\wuauserv /v Start /t REG_DWORD /d 4 /f"

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate]
"DoNotConnectToWindowsUpdateInternetLocations"=dword:00000001
"DisableWindowsUpdateAccess"=dword:00000001
"WUServer"="localhost"
"WUStatusServer"="localhost"
"UpdateServiceUrlAlternate"="localhost"

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU]
"UseWUServer"=dword:00000001
"NoAutoUpdate"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"SettingsPageVisibility"="hide:virus;windowsupdate"
REG

# --- Appx de-provisioning (dynamic, from removed package full names) ---
if [[ ${#REMOVED_FULLNAMES[@]} -gt 0 ]]; then
    {
        echo "Windows Registry Editor Version 5.00"
        echo
        for full in "${REMOVED_FULLNAMES[@]}"; do
            # PackageFamilyName = <Name>_<PublisherId>.
            # PublisherId is the last '_'-delimited field of the full name
            # (covers both Name_Ver_Arch__Pub and Name_Ver_neutral_~_Pub forms).
            family="${full%%_*}_${full##*_}"
            printf '[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications\\%s]\n\n' "$full"
            printf '[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Applications\\%s]\n\n' "$full"
            printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Deprovisioned\\%s]\n\n' "$family"
        done
    } | merge_reg "${HIVE[SOFTWARE]}" 'HKEY_LOCAL_MACHINE\SOFTWARE'
fi

# --- autounattend.xml into Sysprep (local-account OOBE, compact deploy) ---
if [[ -f "$SELF_DIR/autounattend.xml" ]]; then
    sysprep="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Sysprep -type d | head -n1)"
    [[ -n "$sysprep" ]] && cp -f "$SELF_DIR/autounattend.xml" "$sysprep/autounattend.xml"
else
    warn "autounattend.xml not found next to the script; skipping Sysprep copy."
fi

# --- Delete telemetry scheduled-task definition files ---
log "Deleting scheduled task definitions ..."
TASKS="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Tasks -type d | head -n1)"
if [[ -n "$TASKS" ]]; then
    del_task() { local p; p="$(find "$TASKS" -ipath "$TASKS/$1" 2>/dev/null | head -n1)"; [[ -n "$p" ]] && rm -rf "$p"; true; }
    del_task 'Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser'
    del_task 'Microsoft/Windows/Customer Experience Improvement Program'
    del_task 'Microsoft/Windows/Application Experience/ProgramDataUpdater'
    del_task 'Microsoft/Windows/Chkdsk/Proxy'
    del_task 'Microsoft/Windows/Windows Error Reporting/QueueReporting'
fi

# ---------------------------------------------------------------------------
# 10. Commit and export the install image
# ---------------------------------------------------------------------------
log "Committing install image (this can take a while) ..."
wimlib-imagex unmount "$MOUNT" --commit
MOUNTED=""

log "Exporting to solid-compressed install.esd (recovery-equivalent) ..."
ESD_OUT="$SOURCES/install.esd"
wimlib-imagex export "$INSTALL_WIM" "$INDEX" "$ESD_OUT" --solid --check
rm -f "$INSTALL_WIM"

# ---------------------------------------------------------------------------
# 11. Patch boot.wim (setup environment, index 2)
# ---------------------------------------------------------------------------
log "Patching boot image (boot.wim, index 2) ..."
wimlib-imagex mountrw "$BOOT_WIM" 2 "$MOUNT"
MOUNTED="$MOUNT"
locate_hives

merge_reg "${HIVE[DEFAULT]}" 'HKEY_USERS\.DEFAULT' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_USERS\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache]
"SV1"=dword:00000000
"SV2"=dword:00000000
REG

merge_reg "${HIVE[NTUSER]}" 'HKEY_CURRENT_USER' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Control Panel\UnsupportedHardwareNotificationCache]
"SV1"=dword:00000000
"SV2"=dword:00000000
REG

merge_reg "${HIVE[SYSTEM]}" 'HKEY_LOCAL_MACHINE\SYSTEM' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassCPUCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
"BypassTPMCheck"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="X:\\sources\\setup.exe"
REG

log "Committing boot image ..."
wimlib-imagex unmount "$MOUNT" --commit
MOUNTED=""

# ---------------------------------------------------------------------------
# 12. Rebuild the bootable ISO
# ---------------------------------------------------------------------------
log "Building output ISO ..."
# Remove any leftover wimlib FUSE staging dirs so they don't end up in the ISO
# (and don't trip the boot-image lookups below).
find "$SOURCES" -maxdepth 1 -name '*.staging*' -exec rm -rf {} + 2>/dev/null || true
# Look up the boot images in their own subtrees (scoped + error-tolerant, so a
# transient file elsewhere in the tree can't abort us under `set -e`).
ETFS="$(find "$BUILD/boot" -iname etfsboot.com 2>/dev/null | head -n1 || true)"
EFISYS="$(find "$BUILD/efi" -ipath '*/microsoft/boot/efisys.bin' 2>/dev/null | head -n1 || true)"
[[ -f "$ETFS"   ]] || die "etfsboot.com not found in extracted ISO."
[[ -f "$EFISYS" ]] || die "efisys.bin not found in extracted ISO."
# Paths relative to the ISO root, for El Torito.
ETFS_REL="${ETFS#"$BUILD"/}"
EFISYS_REL="${EFISYS#"$BUILD"/}"

# Preserve the original volume id where possible.
VOLID="$(xorriso -indev "$ISO" 2>/dev/null | sed -n "s/.*Volume id[ ]*: '\(.*\)'.*/\1/p" | head -n1 || true)"
[[ -z "$VOLID" ]] && VOLID="TINY11CORE"

rm -f "$OUTPUT"
# Note: xorriso's mkisofs emulation does not support a UDF filesystem; the
# reduced Core install.esd stays well under the 4 GiB ISO9660 file limit, so
# ISO9660 level 3 + Joliet + Rock Ridge is sufficient and boots BIOS + UEFI.
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames \
    -volid "$VOLID" \
    -joliet -joliet-long -rational-rock \
    -b "$ETFS_REL" -no-emul-boot -boot-load-size 8 -boot-info-table \
    -eltorito-alt-boot -e "$EFISYS_REL" -no-emul-boot \
    -o "$OUTPUT" "$BUILD"

log "Done. Output ISO: $OUTPUT"
ls -lh "$OUTPUT"
cat <<EOF

The tiny11 Core image is complete.
  - Image:        $OUTPUT
  - Architecture: $ARCH
  - Language:     $LANG_CODE
  Reminder: this image is NOT serviceable (no updates/features/languages).
EOF
