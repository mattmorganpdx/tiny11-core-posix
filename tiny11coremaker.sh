#!/usr/bin/env bash
#
# tiny11coremaker.sh — POSIX/Linux port of tiny11Coremaker.ps1 (the "Core"
# builder). Produces an ultra-minimal, NON-serviceable Windows 11 ISO: on top
# of the regular debloat it guts WinSxS and removes/disables WinRE, Windows
# Update, and Windows Defender. Best for disposable / template VMs.
#
# Original (PowerShell, Windows-only): https://github.com/ntdevlabs/tiny11builder
# This is an independent reimplementation using Linux tooling. See NOTICE.md.
#
# WARNING: the Core image cannot be serviced — no post-install updates,
# features, or languages.

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/tiny11-common.sh"

# ---------------------------------------------------------------------------
# Builder configuration
# ---------------------------------------------------------------------------
BUILD_MODE="core"
PRODUCT_NAME="tiny11 Core"
OUTPUT_IMAGE_NAME="install.esd"     # Core ships a solid ESD
DEFAULT_OUTPUT_ISO="tiny11core.iso"
BOOT_SET_CMDLINE=1                  # set SYSTEM\Setup\CmdLine on the setup image
COPY_AUTOUNATTEND_ROOT=0

APPX_PREFIXES=(
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

# ---------------------------------------------------------------------------
# Core-only extra removals (run while the install image is mounted)
#
# DISM's offline /Remove-Package servicing has no Linux equivalent, so optional
# components are approximated by deleting their isolated payloads; Defender is
# disabled via the registry; and the WinSxS reduction removes most of the rest.
# ---------------------------------------------------------------------------
extra_removals() {
    log "Removing optional component payloads (best effort) ..."
    local p
    rm_path() { p="$(find "$MOUNT" -maxdepth 6 -ipath "$MOUNT/$1" 2>/dev/null | head -n1)"; [[ -n "$p" ]] && rm -rf "$p" && echo "  - $1"; true; }
    rm_path 'Program Files/Internet Explorer'
    rm_path 'Program Files (x86)/Internet Explorer'
    rm_path 'Program Files/Windows Media Player'
    rm_path 'Program Files (x86)/Windows Media Player'
    rm_path 'Windows/System32/psr.exe'                                   # Steps Recorder
    rm_path 'Program Files/Windows NT/Accessories/wordpad.exe'           # WordPad
    rm_path 'Program Files/Windows NT/Accessories/write.exe'
    rm_path 'Program Files/Common Files/microsoft shared/ink/mip.exe'    # Tablet PC Math

    # Edge WebView component inside WinSxS (architecture-specific)
    local d
    while IFS= read -r d; do [[ -n "$d" ]] && rm -rf "$d"; done < <(
        find "$MOUNT/Windows/WinSxS" -maxdepth 1 -type d \
            -iname "${ARCH}_microsoft-edge-webview_31bf3856ad364e35*" 2>/dev/null)

    log "Removing WinRE ..."
    local recdir winre
    recdir="$(find "$MOUNT/Windows/System32" -maxdepth 1 -iname Recovery -type d | head -n1)"
    if [[ -n "$recdir" ]]; then
        winre="$(find "$recdir" -maxdepth 1 -iname winre.wim | head -n1)"
        [[ -n "$winre" ]] && rm -f "$winre"
        : > "$recdir/winre.wim"      # empty placeholder, as upstream does
    fi

    reduce_winsxs
    return 0
}

reduce_winsxs() {
    log "Reducing WinSxS (this can take a while) ..."
    local WINSXS="$MOUNT/Windows/WinSxS" WINSXS_EDIT="$MOUNT/Windows/WinSxS_edit"
    if [[ ! -d "$WINSXS" ]]; then warn "WinSxS not found; skipping reduction."; return; fi
    mkdir -p "$WINSXS_EDIT"
    local KEEP
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
    local pat src
    for pat in "${KEEP[@]}"; do
        while IFS= read -r src; do
            [[ -z "$src" ]] && continue
            cp -a "$src" "$WINSXS_EDIT/" 2>/dev/null || true
        done < <(find "$WINSXS" -maxdepth 1 -iname "$pat" 2>/dev/null)
    done
    log "Deleting original WinSxS ..."
    rm -rf "$WINSXS"
    mv "$WINSXS_EDIT" "$WINSXS"
    return 0
}

# ---------------------------------------------------------------------------
# Registry — install image
# ---------------------------------------------------------------------------
apply_install_registry() {
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
}

# ---------------------------------------------------------------------------
# Registry — boot/setup image (bypass; lib adds CmdLine via BOOT_SET_CMDLINE)
# ---------------------------------------------------------------------------
apply_boot_registry() {
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
REG
}

tiny11_main "$@"
