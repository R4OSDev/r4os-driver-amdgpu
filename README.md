# AMDGPU

AMDGPU is the external R4OS AMD graphics driver owner, targeting the
Picasso/Vega 8 laptop profile. Version 0.1.3 implements bounded read-only
PCI/ASIC/UMA identification, VFCT/ATOMBIOS board data acquisition and an
immutable boot-frame snapshot through the existing display hold.
The pinned firmware package is validated and retained in driver-owned CPU memory.
Only PCI 1002:15d8 Picasso is admitted; Raven2 is identified separately.

`OPTION AMDGPU mode=auto` (the default) and `mode=passive` perform this
read/capture and firmware-admission path. `mode=native` reports that the native runtime is missing.
The effective kernel software policy, including the one-shot boot-menu
override, wins before PCI, MMIO, heap allocation or firmware reads.
No BAR sizing writes, bus mastering, ROM commands, GPU queues or native
capability are enabled. Physical hardware tests belong only to 0.80.39.

Board acquisition uses the optional ACPI resource tail and validates VFCT
checksum, complete framing, BDF, vendor/device and subsystem identity.
Absent VFCT may use the first 256 KB of a measured prefetchable BAR0 as an
APU ROM shadow. A bare BAR address is not a measured aperture. Corrupt or
changing ACPI never falls through to another source. No ROM BAR enable,
AML method, x86 option ROM or ATOM command execution is used.

Original packed AMD headers supply data offsets and sizes via `@cImport`.
The parser checks all master-data extents, command-directory extents,
overlap, known consumed revisions, GPIO and connector records, panel timing,
integrated UMA data and firmware reservations. Unknown optional formats
are not guessed. Synthetic tests are not a Lenovo ROM or a board capture.

The boot hold captures a consistent frame into a resident BO. Its read
lease stays retained while the hold releases boot writers without effects.
Later native effects require a fresh hold and a DCN register snapshot.
Shutdown releases leases, holds, BOs, firmware-package memory, ROM mappings and heap storage in order;
failed cleanup retains the actual owner and prevents unload/reinitialization.

Build with `./Build.sh` on Linux or `Build.bat` on Windows; both use the same
PowerShell 7 orchestration and local Settings.R4S. Normal builds verify all
pinned hashes and generated register constants, compile the original DCN1
math dependency and run the actual init/shutdown and pure-parser host cases.
`Build.sh test` / `Build.bat test` runs these component checks explicitly.
Regenerate registers only with `Tools/VerifyIdentity.ps1 -Write`.

The package pins linux-firmware commit
`2b8daaf611fbade74f26a5b58ec1defe6a02f5e0`: thirteen unchanged binaries,
original WHENCE, AMD license and a complete lock. A measured Picasso profile
selects twelve binaries, choosing AM4 RLC only for PCI revisions C8-CF/D8-DF;
other Picasso revisions use FP5. Raven and Raven2 are not admitted. Discovery
snapshots are reference-only and are not packaged as required boot firmware.
Header revisions, IP labels, ucode versions, public subranges and SHA256 are
checked. DMCU ERAM/vectors, RLC auxiliary lists, CP jump tables and TA images
remain distinct. SecureDisplay firmware >= 0x27000008 is unavailable on PCI
revision A1, following the pinned PSP10 source. These are dependency checks,
not an implemented TA, video, display or GPU authentication capability.

The resource loader checks a common module generation, bounds every read to
64 KB and a two-second package deadline, and admits at most 512 KB per file
and 2 MB total. A single owner-bound CPU allocation retains only the chosen
profile with its legal metadata. Missing, short, changed or incompatible
resources fail before a display hold; failed release prevents module unload.
`Tools/VerifyFirmware.ps1` checks the exact manifest/resource/hash set.
`Tools/ExportLegal.ps1 -OutputDirectory PATH` exports original firmware
notices and the complete source notices for distribution images.

`IMAGE_SCOPE=none` remains deliberate. The DCN1 math object is not linked
into the runtime yet; its full link/SIMD/assertion contract belongs to
0.80.15. Reports are under Artifacts/Native/AMDGPU/<host>/Portability-7.2.4.
See Docs/Drivers/AMDFirmware08006.txt and AMDBoard08005.txt in the workspace for the detailed scope,
wire compatibility, evidence and hardware limitations.
Original R4OS code is Apache-2.0; AMD notices remain in THIRD_PARTY_NOTICES.md.
