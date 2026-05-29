#!/usr/bin/env bash
#
# tiny11maker.sh — POSIX/Linux port of tiny11maker.ps1 (the regular, SERVICEABLE
# builder). Removes bloat apps, Edge and OneDrive, applies privacy/telemetry and
# hardware-bypass tweaks, and enables local-account OOBE — but KEEPS Windows
# Update, Windows Defender, WinRE and the component store, so the image can
# still receive updates, languages, and features after install.
#
# Original (PowerShell, Windows-only): https://github.com/ntdevlabs/tiny11builder
# This is an independent reimplementation using Linux tooling. See NOTICE.md.
#
# Note: upstream runs `DISM /Cleanup-Image /ResetBase` for extra shrinkage,
# which has no Linux equivalent and is skipped here; the image stays serviceable
# and only slightly larger. The recovery (solid) export still compresses it.

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/tiny11-common.sh"

# ---------------------------------------------------------------------------
# Builder configuration
# ---------------------------------------------------------------------------
BUILD_MODE="standard"
PRODUCT_NAME="tiny11"
OUTPUT_IMAGE_NAME="install.wim"     # regular tiny11 keeps a (solid) install.wim
DEFAULT_OUTPUT_ISO="tiny11.iso"
BOOT_SET_CMDLINE=0
COPY_AUTOUNATTEND_ROOT=1            # upstream also drops it at the ISO root

# Provisioned packages removed by the regular builder (a larger set than Core).
APPX_PREFIXES=(
    'AppUp.IntelManagementandSecurityStatus' 'Clipchamp.Clipchamp'
    'DolbyLaboratories.DolbyAccess' 'DolbyLaboratories.DolbyDigitalPlusDecoderOEM'
    'Microsoft.BingNews' 'Microsoft.BingSearch' 'Microsoft.BingWeather'
    'Microsoft.Copilot' 'Microsoft.Windows.CrossDevice' 'Microsoft.GamingApp'
    'Microsoft.GetHelp' 'Microsoft.Getstarted' 'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftOfficeHub' 'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes' 'Microsoft.MixedReality.Portal'
    'Microsoft.MSPaint' 'Microsoft.Office.OneNote'
    'Microsoft.OfficePushNotificationUtility' 'Microsoft.OutlookForWindows'
    'Microsoft.Paint' 'Microsoft.People' 'Microsoft.PowerAutomateDesktop'
    'Microsoft.SkypeApp' 'Microsoft.StartExperiencesApp' 'Microsoft.Todos'
    'Microsoft.Wallet' 'Microsoft.Windows.DevHome' 'Microsoft.Windows.Copilot'
    'Microsoft.Windows.Teams' 'Microsoft.WindowsAlarms' 'Microsoft.WindowsCamera'
    'microsoft.windowscommunicationsapps' 'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps' 'Microsoft.WindowsSoundRecorder'
    'Microsoft.WindowsTerminal' 'Microsoft.Xbox.TCUI' 'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay' 'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider' 'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.YourPhone' 'Microsoft.ZuneMusic' 'Microsoft.ZuneVideo'
    'MicrosoftCorporationII.MicrosoftFamily' 'MicrosoftCorporationII.QuickAssist'
    'MSTeams' 'MicrosoftTeams' 'Microsoft.549981C3F5F10'
)

# No Core-only destructive removals: extra_removals stays the library no-op,
# so WinSxS, Windows Update, Defender and WinRE are all left intact.

# ---------------------------------------------------------------------------
# Registry — install image (serviceable: no WU/Defender disabling)
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

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate]
"workCompleted"=dword:00000001

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
REG
}

# ---------------------------------------------------------------------------
# Registry — boot/setup image (hardware-requirement bypass only)
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
