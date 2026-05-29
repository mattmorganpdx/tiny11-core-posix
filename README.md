# tiny11-core-posix

**A POSIX/Linux port of [tiny11builder](https://github.com/ntdevlabs/tiny11builder) — build a trimmed-down Windows 11 ISO without Windows, DISM, or Wine.**

The upstream scripts (`tiny11maker.ps1` and `tiny11Coremaker.ps1`) are PowerShell and only run on Windows because they rely on Windows-only tooling (DISM, `reg.exe`, `takeown`/`icacls`, `oscdimg.exe`). This project reproduces their behaviour using standard Linux tools, so you can produce a stripped-down Windows 11 install ISO straight from a Linux box — ideal for lightweight **Proxmox / KVM / VirtualBox** VMs.

It ships **both** builders:

| Script | Based on | Result | Serviceable? | Use for |
|---|---|---|---|---|
| **`tiny11maker.sh`** | `tiny11maker.ps1` | Debloated but normal Windows 11 | ✅ Yes — keeps Windows Update, Defender, WinRE, component store | A lean daily-driver / long-lived VM you still want to patch |
| **`tiny11coremaker.sh`** | `tiny11Coremaker.ps1` | Ultra-minimal (gutted WinSxS, no Update/Defender/WinRE) | ❌ No — cannot add updates/features/languages | Disposable test/dev VMs and golden templates you rebuild |

> ⚠️ **The Core image is NOT serviceable** (same as upstream Core). Pick `tiny11maker.sh` unless you specifically want the smallest possible throwaway image.

Both scripts share their logic via [`lib/tiny11-common.sh`](lib/tiny11-common.sh); each top-level script just defines its package list, registry tweaks, and which extra steps run.

---

## Credits

This is an independent reimplementation. **All credit for the original design — what to strip, which registry tweaks to apply, the whole approach — belongs to NTDEV and the [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder) authors and contributors.** Please support the original project:

- Original repo: <https://github.com/ntdevlabs/tiny11builder>
- Support NTDEV: [Patreon](http://patreon.com/ntdev) · [PayPal](http://paypal.me/ntdev2) · [Ko-fi](http://ko-fi.com/ntdev)

For a Windows-native build, or anything not covered here, use the upstream project on Windows.

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

# Serviceable, debloated build (recommended for most uses):
./tiny11maker.sh --iso /path/to/Win11_24H2_English_x64.iso

# Ultra-minimal, non-serviceable build (disposable VMs / templates):
./tiny11coremaker.sh --iso /path/to/Win11_24H2_English_x64.iso
```

Each script asks you to pick an edition **index** (e.g. Pro, Home), then builds the output ISO in the current directory (`tiny11.iso` / `tiny11core.iso`).

### Options (identical for both scripts)

```
--iso PATH        Source Windows 11 ISO (required)
--scratch DIR     Working directory (default: a fresh mktemp dir; needs ~15-20 GB)
--output FILE     Output ISO path (default: ./tiny11.iso or ./tiny11core.iso)
--index N         Image index to use (skips the interactive prompt)
--lang CODE       UI language override, e.g. en-US (default: autodetected)
-y, --yes         Assume "yes" to prompts (non-interactive)
--keep            Keep the scratch directory on exit (for debugging)
-h, --help        Show help
```

Fully non-interactive example:

```bash
./tiny11maker.sh --iso ~/iso/Win11.iso --index 6 --output ~/tiny11.iso -y
```

> `root` is **not** required. If FUSE mounting fails in your environment, ensure the `fuse` module is loaded and your user may use FUSE.

---

## What it does

**Both builders** remove provisioned bloat apps (and de-provision them in the registry so they don't return for new users / on update), remove **Edge** and **OneDrive**, disable telemetry / sponsored apps / Copilot / the Chat icon, bypass the **TPM / Secure Boot / RAM / CPU / Storage** checks on both the install and setup images, enable **local-account OOBE** (`BypassNRO`) with the bundled `autounattend.xml`, delete telemetry scheduled tasks, and rebuild a bootable **BIOS + UEFI** ISO.

`tiny11maker.sh` strips a larger app set (incl. Camera, Paint, Sticky Notes, OneNote, Skype, Terminal, 3D Viewer, Dolby) but **keeps Windows Update, Defender, WinRE, and the component store** — the image stays fully serviceable.

`tiny11coremaker.sh` does everything above **plus**, for the smallest possible footprint: **reduces WinSxS** to the architecture-specific essential set, **removes WinRE**, **removes the WinSxS Edge WebView**, deletes isolated payloads of optional components (IE, Media Player, WordPad, etc.), and **disables Windows Update and Defender**. The result is **not serviceable**.

Output: `tiny11maker.sh` ships a solid `install.wim`; `tiny11coremaker.sh` ships a solid `install.esd`.

---

## Known limitations vs. the Windows original

These come from not having DISM's offline servicing engine on Linux:

- **Core is not serviceable** (by design, same as upstream Core): no post-install Windows Update, features, or language packs. `tiny11maker.sh` does **not** have this limitation.
- **`DISM /Cleanup-Image /ResetBase`** (run by both upstream scripts for extra shrinkage) has no `wimlib` equivalent and is skipped. For maker the image is just slightly larger and stays serviceable; for Core the WinSxS reduction covers the size goal.
- **Core's optional-package removal** (Internet Explorer, Media Player, WordPad, Tablet PC Math, Steps Recorder, legacy language Handwriting/OCR/Speech/TTS) is done by deleting the safely-isolated payloads rather than via the servicing stack; the rest is removed by the WinSxS reduction. Defender is disabled via the registry.
- **`.NET 3.5` enablement** (upstream Core's optional prompt) uses `DISM /enable-feature`, which has **no Linux equivalent** and is **not supported** here.
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
