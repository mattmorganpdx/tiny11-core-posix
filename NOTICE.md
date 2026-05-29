# Attribution

`tiny11-posix` is an **independent, from-scratch reimplementation** (in Bash,
using Linux tooling) of the *Core* builder from the **tiny11builder** project.

## Original work

- **Project:** tiny11builder
- **Author:** NTDEV (ntdevlabs) and contributors
- **Source:** https://github.com/ntdevlabs/tiny11builder
- **Original script ported here:** `tiny11Coremaker.ps1` (PowerShell, Windows-only)

All credit for the original concept and design — the selection of which apps,
packages, and components to remove; the registry modifications; the WinSxS
reduction strategy; and the overall build pipeline — belongs to the original
authors. Please support and reference the upstream project:

- Patreon: http://patreon.com/ntdev
- PayPal:  http://paypal.me/ntdev2
- Ko-fi:   http://ko-fi.com/ntdev

## What is derived

The following are functionally derived from the upstream `tiny11Coremaker.ps1`:

- the list of provisioned Appx package prefixes to remove,
- the offline registry tweaks (hardware-check bypass, telemetry, sponsored apps,
  Windows Update / Defender disabling, local-account OOBE, etc.),
- the architecture-specific WinSxS keep-lists,
- the `autounattend.xml` answer file (copied verbatim from upstream),
- the overall sequence of operations.

## What is original

The Bash implementation, the translation of every Windows operation to Linux
tooling (`wimlib-imagex`, `hivexregedit`, `xorriso`, `7z`), the argument
handling, error handling, and packaging are original to this project.

## Note on upstream licensing

At the time of writing, the upstream tiny11builder repository does not include an
explicit license file. This port redistributes none of its source; it
reimplements the behaviour. For the canonical, Windows-native tool, use the
upstream project directly.

## Trademarks

Windows and Windows 11 are trademarks of Microsoft Corporation. This project
ships no Microsoft software and is not affiliated with or endorsed by Microsoft.
You must supply your own legally-obtained Windows 11 ISO and hold a valid license.
