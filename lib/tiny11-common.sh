#!/usr/bin/env bash
#
# tiny11-common.sh — shared library for the POSIX/Linux tiny11 builders.
#
# Sourced by tiny11coremaker.sh (Core) and tiny11maker.sh (regular). It holds
# everything the two builders share: argument parsing, ISO extract, edition/ESD
# handling, WIM mount/commit, Appx removal + de-provisioning, Edge/OneDrive
# removal, scheduled-task cleanup, the registry-merge engine, image export, and
# the bootable-ISO rebuild.
#
# A wrapper script sets a few config variables and defines the parts that
# differ between builders, then calls `tiny11_main "$@"`:
#
#   Required config vars:
#     BUILD_MODE            "core" | "standard"   (banner text only)
#     PRODUCT_NAME          e.g. "tiny11 Core"
#     OUTPUT_IMAGE_NAME     "install.esd" | "install.wim"
#     DEFAULT_OUTPUT_ISO    e.g. "tiny11core.iso"
#     APPX_PREFIXES         array of provisioned-package name prefixes to remove
#   Optional config vars (default 0):
#     BOOT_SET_CMDLINE          1 => set SYSTEM\Setup\CmdLine on boot image (Core)
#     COPY_AUTOUNATTEND_ROOT    1 => also drop autounattend.xml at the ISO root
#   Required hook functions (defined by the wrapper):
#     apply_install_registry    apply registry tweaks to the mounted install image
#     apply_boot_registry       apply registry tweaks to the mounted boot image
#   Optional hook functions (default no-op provided here):
#     extra_removals            extra offline deletions (Core: WinSxS/WinRE/etc.)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

find_ci() { find "$1" -maxdepth 1 -iname "$2" 2>/dev/null | head -n1; }

# ---------------------------------------------------------------------------
# Defaults for optional config / hooks
# ---------------------------------------------------------------------------
: "${BOOT_SET_CMDLINE:=0}"
: "${COPY_AUTOUNATTEND_ROOT:=0}"
extra_removals() { :; }   # no-op unless the wrapper overrides it

SEVENZIP=""
pick_7z() {
    for c in 7zz 7z 7za; do command -v "$c" >/dev/null 2>&1 && { SEVENZIP="$c"; return; }; done
    die "7z not found (install p7zip-full)."
}

# ---------------------------------------------------------------------------
# Cleanup / trap
# ---------------------------------------------------------------------------
MOUNTED=""
cleanup() {
    set +e
    if [[ -n "$MOUNTED" ]] && mountpoint -q "$MOUNTED" 2>/dev/null; then
        log "Cleaning up: unmounting WIM (discarding) ..."
        wimlib-imagex unmount "$MOUNTED" >/dev/null 2>&1
    fi
    if [[ "${KEEP_SCRATCH:-0}" -eq 0 && -n "${SCRATCH:-}" && -d "${SCRATCH:-}" && "${SCRATCH_OWNED:-0}" -eq 1 ]]; then
        log "Cleaning up scratch dir $SCRATCH ..."
        rm -rf "$SCRATCH"
    fi
}

# ---------------------------------------------------------------------------
# Registry merge engine
#
# hivexregedit's --merge only creates a key if its IMMEDIATE parent already
# exists (unlike reg.exe). So we expand every "[create]" block into its
# ancestor chain (shallow -> deep) first. Re-declaring an existing key is
# harmless. Delete blocks ("[-...]") pass through untouched.
# ---------------------------------------------------------------------------
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
        /^\[-/ { print; next }
        /^\[/  {
            key = substr($0, 2, length($0) - 2)
            emit_ancestors(key)
            print
            next
        }
        { print }
    ' > "$tmp"
    hivexregedit --merge --prefix "$prefix" "$hive" "$tmp" \
        || die "hivexregedit merge failed for $hive (prefix $prefix)"
    rm -f "$tmp"
}

# Locate the registry hive files inside the current mount (case-insensitive).
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
# Argument parsing
# ---------------------------------------------------------------------------
ISO=""; SCRATCH=""; OUTPUT=""; INDEX=""; LANG_CODE=""; ASSUME_YES=0; KEEP_SCRATCH=0
usage() {
    cat <<USAGE
$(basename "$0") — build a $PRODUCT_NAME (reduced Windows 11) ISO on Linux.

Usage:
  $(basename "$0") --iso <path-to-windows11.iso> [options]

Options:
  --iso PATH        Source Windows 11 ISO (required).
  --scratch DIR     Working directory (default: a fresh mktemp dir; needs ~15-20 GB).
  --output FILE     Output ISO path (default: ./$DEFAULT_OUTPUT_ISO).
  --index N         Image index to use (skips the interactive prompt).
  --lang CODE       UI language code override, e.g. en-US (default: autodetect).
  -y, --yes         Assume "yes" to confirmation prompts (non-interactive).
  --keep            Do not delete the scratch directory on exit.
  -h, --help        Show this help.

Dependencies: wimtools, libwin-hivex-perl, libhivex-bin, p7zip-full, xorriso.
  Debian/Ubuntu: sudo apt install wimtools libwin-hivex-perl libhivex-bin p7zip-full xorriso
USAGE
}
parse_args() {
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
}

preflight() {
    [[ -n "$ISO" ]] || { usage; die "--iso is required."; }
    [[ -f "$ISO" ]] || die "ISO not found: $ISO"
    ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"
    local missing=()
    for t in wimlib-imagex hivexregedit hivexget xorriso; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    pick_7z
    [[ ${#missing[@]} -eq 0 ]] || die "Missing tools: ${missing[*]}
Install with: sudo apt install wimtools libwin-hivex-perl libhivex-bin p7zip-full xorriso"
}

banner_and_confirm() {
    if [[ "$BUILD_MODE" == "core" ]]; then
        cat <<BANNER
============================================================
  $PRODUCT_NAME builder — POSIX/Linux port
------------------------------------------------------------
  This generates a SIGNIFICANTLY reduced Windows 11 image.
  It is NOT serviceable: you cannot add languages, updates,
  or features afterwards. Best for disposable / template VMs.
============================================================
BANNER
    else
        cat <<BANNER
============================================================
  $PRODUCT_NAME builder — POSIX/Linux port
------------------------------------------------------------
  Builds a trimmed-but-serviceable Windows 11 image: bloat
  and Edge/OneDrive removed, but Windows Update, Defender,
  WinRE and the component store are kept intact.
============================================================
BANNER
    fi
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        read -r -p "Do you want to continue? (y/N) " ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }
    fi
}

# ---------------------------------------------------------------------------
# Pipeline stages
# ---------------------------------------------------------------------------
setup_paths() {
    SCRATCH_OWNED=0
    if [[ -z "$SCRATCH" ]]; then
        SCRATCH="$(mktemp -d -t tiny11.XXXXXX)"; SCRATCH_OWNED=1
    else
        mkdir -p "$SCRATCH"
    fi
    SCRATCH="$(cd "$SCRATCH" && pwd)"
    BUILD="$SCRATCH/tiny11"
    MOUNT="$SCRATCH/scratchdir"
    SOURCES="$BUILD/sources"
    [[ -z "$OUTPUT" ]] && OUTPUT="$(pwd)/$DEFAULT_OUTPUT_ISO"
    mkdir -p "$BUILD" "$MOUNT"
    log "Scratch:  $SCRATCH"
    log "Output:   $OUTPUT"
}

extract_iso() {
    log "Extracting source ISO (this can take a few minutes) ..."
    "$SEVENZIP" x -y -o"$BUILD" "$ISO" >/dev/null
    chmod -R u+w "$BUILD"
    [[ -d "$SOURCES" ]] || SOURCES="$(find_ci "$BUILD" sources)"
    [[ -d "$SOURCES" ]] || die "No 'sources' directory in the ISO — is this a Windows 11 ISO?"
    INSTALL_WIM="$(find_ci "$SOURCES" install.wim || true)"
    INSTALL_ESD="$(find_ci "$SOURCES" install.esd || true)"
    BOOT_WIM="$(find_ci "$SOURCES" boot.wim || true)"
    [[ -f "$BOOT_WIM" ]] || die "sources/boot.wim missing."
}

resolve_install_wim() {
    if [[ ! -f "$INSTALL_WIM" ]]; then
        [[ -f "$INSTALL_ESD" ]] || die "Neither install.wim nor install.esd found in sources."
        log "Found install.esd. Available editions:"
        wimlib-imagex info "$INSTALL_ESD" | grep -E '^(Index|Name|Description)' || true
        if [[ -z "$INDEX" ]]; then read -r -p "Enter the image index to convert: " INDEX; fi
        log "Converting install.esd -> install.wim (index $INDEX, LZX). This may take a while ..."
        INSTALL_WIM="$SOURCES/install.wim"
        wimlib-imagex export "$INSTALL_ESD" "$INDEX" "$INSTALL_WIM" --compress=LZX --check
    fi
    if [[ -n "$INSTALL_ESD" && -f "$INSTALL_ESD" ]]; then rm -f "$INSTALL_ESD"; fi
    log "Image information:"
    wimlib-imagex info "$INSTALL_WIM" | grep -E '^(Index|Name|Description|Architecture)' || true
    if [[ -z "$INDEX" ]]; then read -r -p "Enter the image index to build from: " INDEX; fi
    return 0
}

detect_arch_lang() {
    local info; info="$(wimlib-imagex info "$INSTALL_WIM" "$INDEX")"
    local arch_raw; arch_raw="$(printf '%s\n' "$info" | sed -n 's/^Architecture[[:space:]]*[:=][[:space:]]*//p' | head -n1)"
    case "${arch_raw,,}" in
        *aarch64*|*arm64*)      ARCH="arm64" ;;
        *x86_64*|*amd64*|*x64*) ARCH="amd64" ;;
        *x86*|*i386*)           ARCH="x86" ;;
        *) ARCH="amd64"; warn "Unknown architecture '$arch_raw'; assuming amd64." ;;
    esac
    log "Architecture: $ARCH"
    if [[ -z "$LANG_CODE" ]]; then
        LANG_CODE="$(printf '%s\n' "$info" | sed -n 's/^Default Language[[:space:]]*[:=][[:space:]]*//p' | head -n1)"
        [[ -z "$LANG_CODE" ]] && LANG_CODE="$(printf '%s\n' "$info" | sed -n 's/^Languages[[:space:]]*[:=][[:space:]]*//p' | head -n1 | awk '{print $1}')"
        [[ -z "$LANG_CODE" ]] && LANG_CODE="en-US"
    fi
    log "UI language: $LANG_CODE"
}

mount_install() {
    log "Mounting install image (index $INDEX) ..."
    wimlib-imagex mountrw "$INSTALL_WIM" "$INDEX" "$MOUNT"
    MOUNTED="$MOUNT"
}

# Remove provisioned Appx packages whose folder name matches one of
# $APPX_PREFIXES; record full names in REMOVED_FULLNAMES for de-provisioning.
REMOVED_FULLNAMES=()
remove_appx() {
    log "Removing provisioned apps ..."
    local WINAPPS APPREPO prefix d name
    WINAPPS="$(find "$MOUNT" -maxdepth 2 -ipath '*/Program Files/WindowsApps' -type d | head -n1)"
    APPREPO="$(find "$MOUNT" -maxdepth 5 -ipath '*/AppRepository/Packages' -type d | head -n1)"
    if [[ ! -d "$WINAPPS" ]]; then warn "WindowsApps folder not found; skipping payload deletion."; return; fi
    for prefix in "${APPX_PREFIXES[@]}"; do
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            name="$(basename "$d")"
            echo "  - $name"
            REMOVED_FULLNAMES+=("$name")
            rm -rf "$d"
            [[ -d "$APPREPO" ]] && find "$APPREPO" -maxdepth 1 -name "$name" -exec rm -rf {} + 2>/dev/null || true
        done < <(find "$WINAPPS" -maxdepth 1 -type d -iname "${prefix}*" 2>/dev/null)
    done
    return 0
}

remove_edge_onedrive() {
    log "Removing Edge ..."
    local sub p
    for sub in "Edge" "EdgeUpdate" "EdgeCore"; do
        p="$(find "$MOUNT" -maxdepth 5 -ipath "*/Program Files (x86)/Microsoft/$sub" -type d | head -n1)"
        [[ -n "$p" ]] && rm -rf "$p"
    done
    p="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname "Microsoft-Edge-Webview" -type d | head -n1)"
    [[ -n "$p" ]] && rm -rf "$p"
    log "Removing OneDrive setup ..."
    local od; od="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname OneDriveSetup.exe | head -n1)"
    if [[ -n "$od" ]]; then rm -f "$od"; else warn "OneDriveSetup.exe not present (expected on arm64)."; fi
}

# De-provision removed Appx in the SOFTWARE hive so they don't return for new
# users / on update. PackageFamilyName = <Name>_<PublisherId> (last '_' field).
appx_deprovision() {
    [[ ${#REMOVED_FULLNAMES[@]} -eq 0 ]] && return
    local full family
    {
        echo "Windows Registry Editor Version 5.00"; echo
        for full in "${REMOVED_FULLNAMES[@]}"; do
            family="${full%%_*}_${full##*_}"
            printf '[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications\\%s]\n\n' "$full"
            printf '[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Applications\\%s]\n\n' "$full"
            printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Deprovisioned\\%s]\n\n' "$family"
        done
    } | merge_reg "${HIVE[SOFTWARE]}" 'HKEY_LOCAL_MACHINE\SOFTWARE'
}

copy_autounattend() {
    local sysprep
    if [[ -f "$SELF_DIR/autounattend.xml" ]]; then
        sysprep="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Sysprep -type d | head -n1)"
        if [[ -n "$sysprep" ]]; then cp -f "$SELF_DIR/autounattend.xml" "$sysprep/autounattend.xml"; fi
    else
        warn "autounattend.xml not found next to the script; skipping Sysprep copy."
    fi
    return 0
}

delete_tasks() {
    log "Deleting scheduled task definitions ..."
    local TASKS; TASKS="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Tasks -type d | head -n1)"
    [[ -z "$TASKS" ]] && return
    local t p
    for t in \
        'Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser' \
        'Microsoft/Windows/Customer Experience Improvement Program' \
        'Microsoft/Windows/Application Experience/ProgramDataUpdater' \
        'Microsoft/Windows/Chkdsk/Proxy' \
        'Microsoft/Windows/Windows Error Reporting/QueueReporting'; do
        p="$(find "$TASKS" -ipath "$TASKS/$t" 2>/dev/null | head -n1)"; [[ -n "$p" ]] && rm -rf "$p"
    done
    true
}

finalize_image() {
    log "Committing install image (this can take a while) ..."
    wimlib-imagex unmount "$MOUNT" --commit
    MOUNTED=""
    log "Exporting to solid-compressed $OUTPUT_IMAGE_NAME ..."
    local tmp="$SOURCES/.image.export.tmp"
    rm -f "$tmp"
    wimlib-imagex export "$INSTALL_WIM" "$INDEX" "$tmp" --solid --check
    rm -f "$INSTALL_WIM"
    mv "$tmp" "$SOURCES/$OUTPUT_IMAGE_NAME"
}

patch_bootwim() {
    log "Patching boot image (boot.wim, index 2) ..."
    wimlib-imagex mountrw "$BOOT_WIM" 2 "$MOUNT"
    MOUNTED="$MOUNT"
    locate_hives
    apply_boot_registry
    if [[ "$BOOT_SET_CMDLINE" -eq 1 ]]; then
        merge_reg "${HIVE[SYSTEM]}" 'HKEY_LOCAL_MACHINE\SYSTEM' <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="X:\\sources\\setup.exe"
REG
    fi
    log "Committing boot image ..."
    wimlib-imagex unmount "$MOUNT" --commit
    MOUNTED=""
}

build_iso() {
    log "Building output ISO ..."
    if [[ "$COPY_AUTOUNATTEND_ROOT" -eq 1 && -f "$SELF_DIR/autounattend.xml" ]]; then
        cp -f "$SELF_DIR/autounattend.xml" "$BUILD/autounattend.xml"
    fi
    find "$SOURCES" -maxdepth 1 -name '*.staging*' -exec rm -rf {} + 2>/dev/null || true
    local ETFS EFISYS ETFS_REL EFISYS_REL VOLID
    ETFS="$(find "$BUILD/boot" -iname etfsboot.com 2>/dev/null | head -n1 || true)"
    EFISYS="$(find "$BUILD/efi" -ipath '*/microsoft/boot/efisys.bin' 2>/dev/null | head -n1 || true)"
    [[ -f "$ETFS"   ]] || die "etfsboot.com not found in extracted ISO."
    [[ -f "$EFISYS" ]] || die "efisys.bin not found in extracted ISO."
    ETFS_REL="${ETFS#"$BUILD"/}"; EFISYS_REL="${EFISYS#"$BUILD"/}"
    VOLID="$(xorriso -indev "$ISO" 2>/dev/null | sed -n "s/.*Volume id[ ]*: '\(.*\)'.*/\1/p" | head -n1 || true)"
    [[ -z "$VOLID" ]] && VOLID="TINY11"
    rm -f "$OUTPUT"
    # xorriso's mkisofs emulation has no UDF; the reduced image stays under the
    # 4 GiB ISO9660 file limit, so ISO9660 L3 + Joliet + Rock Ridge suffices and
    # boots both BIOS and UEFI.
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

The $PRODUCT_NAME image is complete.
  - Image:        $OUTPUT
  - Architecture: $ARCH
  - Language:     $LANG_CODE
EOF
    if [[ "$BUILD_MODE" == "core" ]]; then
        echo "  Reminder: this image is NOT serviceable (no updates/features/languages)."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
tiny11_main() {
    parse_args "$@"
    preflight
    banner_and_confirm
    trap cleanup EXIT INT TERM
    setup_paths
    extract_iso
    resolve_install_wim
    detect_arch_lang
    mount_install
    remove_appx
    extra_removals           # Core: WinSxS reduction, WinRE, system pkgs, etc.
    remove_edge_onedrive
    log "Applying registry tweaks (install image) ..."
    locate_hives
    apply_install_registry   # wrapper-provided
    appx_deprovision
    copy_autounattend
    delete_tasks
    finalize_image
    patch_bootwim
    build_iso
}
