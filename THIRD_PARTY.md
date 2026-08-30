# Third-party components

PC Power Widget is MIT-licensed, but it interoperates with independent third-party projects under their own licenses.

## LibreHardwareMonitor

- Project: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
- Version used by installer: 0.9.6
- Downloaded by the installer from the official GitHub release.

## Intel PresentMon

- Project: https://github.com/GameTechDev/PresentMon
- Version used by installer: 2.5.1
- Downloaded by the installer from the official GitHub release.
- The downloaded executable is SHA256 verified by the installer.

## PawnIO

- Project: https://github.com/namazso/PawnIO
- Official releases: https://github.com/namazso/PawnIO.Setup
- Version offered by installer: 2.2.0
- Upstream license: GPL-2.0-or-later; see the upstream repository for the complete terms.
- Official signed installer URL used by PC Power Widget: https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe
- Expected SHA256 for `PawnIO_setup.exe` v2.2.0: `1f519a22e47187f70a1379a48ca604981c4fcf694f4e65b734aaa74a9fba3032`

PawnIO binaries are **not redistributed** by PC Power Widget. When CPU low-level telemetry is unavailable and the user agrees, the installer downloads the official signed PawnIO installer directly from the upstream release, verifies its SHA256 digest, and runs the upstream installer.

PawnIO is not covered by PC Power Widget's MIT license.
