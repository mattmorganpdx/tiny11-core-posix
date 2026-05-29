# tiny11-core-posix

**A POSIX/Linux port of the [tiny11builder](https://github.com/ntdevlabs/tiny11builder) *Core* script — build an ultra-minimal Windows 11 ISO without Windows, DISM, or Wine.**

The upstream [`tiny11Coremaker.ps1`](https://github.com/ntdevlabs/tiny11builder) is a PowerShell script that only runs on Windows because it relies on Windows-only tooling (DISM, `reg.exe`, `takeown`/`icacls`, `oscdimg.exe`). This project reproduces its behaviour using standard Linux tools, so you can produce a stripped-down Windows 11 install ISO straight from a Linux box — ideal for spinning up lightweight, disposable **Proxmox / KVM / VirtualBox** VM templates.

> ⚠️ **This builds the *Core* image, which is NOT serviceable.** You cannot install updates, languages, or features afterwards. It is meant for throwaway test/dev VMs and golden templates you rebuild periodically — not as a long-lived, internet-facing daily driver. This mirrors the upstream Core script's design.

---

## Credits

This is an independent reimplementation. **All credit for the original design — what to strip, which registry tweaks to apply, the whole approach — belongs to NTDEV and the [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder) authors and contributors.** Please support the original project:

- Original repo: <https://github.com/ntdevlabs/tiny11builder>
- Support NTDEV: [Patreon](http://patreon.com/ntdev) · [PayPal](http://paypal.me/ntdev2) · [Ko-fi](http://ko-fi.com/ntdev)

If you want a Windows-native, *serviceable* build (the regular `tiny11maker.ps1`), or the official Core script, use the upstream project on Windows.

---

## How it maps to the original

| Original (Windows) | This port (Linux) |
|---|---|
| DISM `mount` / `unmount /commit` | `wimlib-imagex mountrw` / `unmount --commit` (FUSE) |
| DISM `/Export-Image /Compress:recovery` | `wimlib-imagex export --solid` (LZMS) |
| DISM `/Get-WimInfo`, `/Get-Intl` | `wimlib-imagex info` |
| `reg load` / `reg add` / `reg delete` | `hivexregedit --merge` on offline hives |
| `takeown` / `icacls` | not needed — we own the FUSE mount |
| `oscdimg.exe` | `xorriso -as mkisofs` (BIOS + UEFI El Torito) |
| ISO mount + copy | `7z` extraction of the source ISO |

---

## Requirements

- A Linux host with FUSE available (the WIM is mounted read-write via FUSE).
- ~15–20 GB free disk in the scratch directory.
- An **official Windows 11 ISO** (download from Microsoft). This tool does **not** download Windows for you.

### Install dependencies (Debian/Ubuntu)

```bash
sudo apt install wimtools libwin-hivex-perl libhivex-bin p7zip-full xorriso
```

- `wimtools` → `wimlib-imagex`
- `libwin-hivex-perl` → `hivexregedit`
- `libhivex-bin` → `hivexget` / `hivexsh`
- `p7zip-full` → `7z`
- `xorriso`

(Fedora: `wimlib-utils hivex perl-hivex p7zip xorriso`. Arch: `wimlib hivex p7zip libisoburn`.)

---

## Usage

```bash
git clone https://github.com/<your-user>/tiny11-core-posix.git
cd tiny11-core-posix
chmod +x tiny11coremaker.sh

./tiny11coremaker.sh --iso /path/to/Win11_24H2_English_x64.iso
```

It will ask you to pick an edition **index** (e.g. Pro, Home), then build `tiny11core.iso` in the current directory.

### Options

```
--iso PATH        Source Windows 11 ISO (required)
--scratch DIR     Working directory (default: a fresh mktemp dir; needs ~15-20 GB)
--output FILE     Output ISO path (default: ./tiny11core.iso)
--index N         Image index to use (skips the interactive prompt)
--lang CODE       UI language override, e.g. en-US (default: autodetected)
-y, --yes         Assume "yes" to prompts (non-interactive)
--keep            Keep the scratch directory on exit (for debugging)
-h, --help        Show help
```

Fully non-interactive example:

```bash
./tiny11coremaker.sh --iso ~/iso/Win11.iso --index 6 --output ~/tiny11core.iso -y
```

> `root` is **not** required. If FUSE mounting fails in your environment, ensure the `fuse` module is loaded and your user may use FUSE.

---

## What it does

Faithful to the upstream Core script:

- **Removes provisioned apps** (Clipchamp, Bing News/Weather, Xbox/Gaming, Get Help, Get Started, Office Hub, Solitaire, People, Power Automate, To Do, Alarms, Mail & Calendar, Feedback Hub, Maps, Sound Recorder, Your Phone, Zune Music/Video, Family, Quick Assist, Teams, Copilot, Outlook for Windows, …). Staged payloads are deleted and the packages are de-provisioned in the registry (so they don't return for new users / on update).
- **Removes Edge** (Edge, EdgeUpdate, EdgeCore, the WinSxS WebView component, `Microsoft-Edge-Webview`) and its uninstall registry entries.
- **Removes OneDrive** setup and disables OneDrive folder backup.
- **Removes WinRE** (`winre.wim` replaced with an empty placeholder, as upstream does).
- **Reduces WinSxS** to the architecture-specific essential runtime/servicing set — the largest space saving.
- **Disables Windows Update** (services, policies, and post-OOBE `RunOnce` shutdown) and **Windows Defender** (services set to disabled, Security page hidden).
- **Bypasses TPM / Secure Boot / RAM / CPU / Storage checks** on both the install image and the setup (boot) image.
- **Disables telemetry**, sponsored/suggested apps, Copilot, the Chat icon, and consumer features.
- **Enables local-account OOBE** (`BypassNRO`) and copies an `autounattend.xml` that hides the online-account screens and deploys with `/compact`.
- **Deletes telemetry scheduled tasks** (Compatibility Appraiser, CEIP, ProgramDataUpdater, Chkdsk Proxy, Error Reporting QueueReporting).
- **Re-exports** the install image as solid-compressed `install.esd` (the recovery-compression equivalent) and **rebuilds a bootable BIOS+UEFI ISO** with `xorriso`.

---

## Known limitations vs. the Windows original

These come from not having DISM's offline servicing engine on Linux. They're acceptable for the Core image's intended disposable-VM use, but be aware:

- **Not serviceable** (same as upstream Core, by design): no post-install Windows Update, features, or language packs. Turning Windows Update back on can break the system.
- **Optional Windows packages** that upstream removes with `DISM /Remove-Package` (Internet Explorer, Media Player, WordPad, Tablet PC Math, Steps Recorder, legacy language Handwriting/OCR/Speech/TTS, Wallpaper FoD) are **not removed via the servicing stack**. This port deletes the safely-isolated payloads it can and disables Defender via the registry; the rest of those components are largely removed by the WinSxS reduction. Net result is comparable in size, but the package database still lists them.
- **`.NET 3.5` enablement** (upstream's optional Core prompt) uses `DISM /enable-feature`, which has **no Linux equivalent** and is **not supported** here. (Rarely needed for a lightweight VM.)
- **`DISM /Cleanup-Image /StartComponentCleanup /ResetBase`** has no `wimlib` equivalent; the WinSxS reduction plus the solid-ESD export cover the size reduction instead.
- **Language autodetection** is best-effort (defaults to `en-US`; override with `--lang`).

---

## Verifying the result

```bash
# Output ISO and its install image
7z l tiny11core.iso | grep -i install
wimlib-imagex info <(7z x -so tiny11core.iso sources/install.esd) 2>/dev/null || true

# Boot in a Proxmox / QEMU UEFI VM (OVMF). The TPM/Secure Boot bypass means
# you do NOT need a vTPM. Setup should reach a LOCAL account (no MS account),
# and Edge/OneDrive/Defender/Update should be absent or disabled.
```

---

## License

This port's own source code is released under the **MIT License** (see [`LICENSE`](LICENSE)). Attribution to the upstream tiny11builder project is in [`NOTICE.md`](NOTICE.md). Upstream itself ships no license file; this project redistributes none of its source.

---

## Disclaimer

Windows 11 is a trademark of Microsoft. You must own a valid Windows license and use your own legally-obtained ISO. This tool only repackages an image you already have; it ships no Microsoft binaries. Provided as-is, with no warranty. Modifying a Windows image is unsupported by Microsoft.
