# AMDGPU

AMDGPU is the external R4OS AMD graphics driver owner, targeting the
Picasso/Vega 8 laptop profile. Version 0.1.6 implements bounded read-only
PCI/ASIC/UMA identification, VFCT/ATOMBIOS board data acquisition and an
immutable boot-frame snapshot through the existing display hold.
The pinned firmware package is validated and retained in driver-owned CPU memory.
Only PCI 1002:15d8 Picasso is admitted; Raven2 is identified separately.

`OPTION AMDGPU mode=auto` (the default) and `mode=passive` perform this
read/capture, firmware admission and UMA reservation plan. `mode=native` reports that the native runtime is missing.
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
Regenerate registers only with `Tools/VerifyIdentity.ps1 -Write` and
`Tools/VerifyMemory.ps1 -Write`, `Tools/VerifyQueue.ps1 -Write` and
`Tools/VerifyStart.ps1 -Write`.

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

The memory owner distinguishes CPU virtual addresses, CPU-physical UMA,
MC aperture addresses, pinned system DMA pages and GPU virtual addresses.
GFXHUB and MMHUB framebuffer location must agree. The generic optional
`reserved_span` API proves complete boot-map reservation before UMA admission;
no pages are added to host RAM or charged twice. Boot/firmware reservations
form a union. Separate 16 MB firmware, 2 MB GART-table, 1 MB ring and 2 MB
context/table arenas leave the actual remainder as native BO budget.
ATOM v2.1 driver scratch is a CPU-interpreter request, not a VRAM region.

`memory_owner.zig` provides WC table windows, canonical native BO ownership,
budgeting, flat 1 GB GART and four-level 48-bit GPU VA. `memory_mapping.zig`
retains shared SG DMA or native UMA references, GPU-VA leases and exact fence
identities. It removes translations and confirms both hub TLB acknowledgements
before releasing backing; failures retain the owner. CPU-WB system mappings
and CPU-WC UMA mappings remain separate; no app CPU map of device-local BOs is
invented. WINSVC keeps its adapter/memory-generation/device-local contract.

The GMC9/ATHUB controller requires parked engines and a held boot display.
These production primitives and their real SDK/MMIO adapters are exercised
with host fixtures. The passive entry point only admits the measured layout;
the internal PSP/SMU start entry is implemented in 0.80.9. SDMA/GFX ring
launch and GMC/IH activation are composed by the subsequent engine owners.
The queue foundation remains inactive during passive admission.
No new GPU capability is advertised here. A four-CPU QEMU probe validates the
real generic reserved-span API, old ABI prefixes and common BO/SG lifetime;
it does not emulate Picasso memory hardware. Full evidence:
`Docs/Drivers/AMDSpeicher08007.txt` and its JSON companion in the workspace.

The firmware display label is `linux-firmware-2b8daaf611fb`; the complete
40-character revision and exact file hashes remain in the package lock.

The queue runtime partitions the 1 MB UMA ring arena into a 64 KB IH ring,
writeback page, three 64 KB engine rings, and 64 fixed 8 KB IB slots. It maps
one UC doorbell page and keeps a separate canonical 4 KB system BO with its
real DMA segment for NBIO's dummy read. This address is not a VRAM MC alias.
The Vega10 IH controller uses pinned AMD definitions, a bounded resident
mailbox, MSI or validated INTx, and a nonblocking 1 ms stop/drain interval.

A dedicated worker consumes IRQ metadata, polls exact per-job writebacks,
and publishes canonical fence results after resource cleanup. Tokens are
never recycled within a runtime; memory, queue and reset generations stay
separate. Lost IRQs, ring wrap, stale values, overflow, deadline and partial
teardown are covered by three integrated host cases. Failure retains DMA,
BOs, IRQ callbacks and task handles until their respective owners confirm
retirement. A closed notification gate remains resident until the outer
native owner unregisters the canonical backend; only then may it reset this
runtime or unload the module. No new global test gate or kernel ABI is added.
See `Docs/Drivers/AMDQueues08008.txt` and its JSON evidence in the workspace.
Engine-specific packet emission/ring launch follows in 0.80.10/11; neither
an IRQ fixture nor a host-written test writeback is physical GPU execution.

The resident native-start owner uses a fresh canonical boot hold, validates
actual linear DCN1 scanout/routing/timing registers and latches retention
before PCI bus mastering or firmware effects. SMU10 version/interface replies
must succeed (driver interface 6 or 7); GFXOFF exit and SDMA power-up precede
confirmed CP/MEC/SDMA/RLC halts. The startup register generator uses the
runtime IP_BASE table: the similarly named MP1 SEG0 macro has a different
address and is not the table consumed by Linux SOC15.

PSP10 gets its real 4 KB GPCOM ring, 4 KB command/fence pages, 512 KB staging
and naturally aligned 4 MB TMR inside the reserved 16 MB UMA arena. Original
C headers prove wire offsets, including the distinct MC/system-physical TMR
addresses. Ordered uploads cover SDMA, CE/PFP/ME, both MECs and separate jump
tables, the selected RLC restore sections and RLC, then ASD. Firmware-ready
requires exact fence tokens and successful PSP responses for every image.
VCN, DMCU and optional TAs remain with their later IP owners. Picasso's SOS
and SMU come from platform firmware; modern RLC autoload and PSP Mode1 reset
are not assumed. No display clocks, panel training or ATOM code are changed.

Every startup failure enters the same bounded drain and reverse teardown.
Late replies can be observed only for cleanup; unconfirmed DMA retains TMR,
BOs, mappings and the boot hold. Successful teardown unloads ASD, destroys
TMR, stops the PSP ring, restores PCI command bits and proves the unchanged
original scanout before releasing boot writers. Recovery compares the actual
pending generation/preparing-state callback ABI. Four grouped host cases
exercise protocols, failures, DCN guard and real SDK/MMIO/hold integration.
`beginNative` / `start_runtime.Owner` are internal start-worker entry points;
firmware-ready is distinct from a ready device. `mode=native` remains gated
until the subsequent ring/display owners complete their integration.
See `Docs/Drivers/AMDStart08009.txt` and its JSON evidence in the workspace.

`IMAGE_SCOPE=none` remains deliberate. The DCN1 math object is not linked
into the runtime yet; its full link/SIMD/assertion contract belongs to
0.80.15. Reports are under Artifacts/Native/AMDGPU/<host>/Portability-7.2.4.
See Docs/Drivers/AMDFirmware08006.txt and AMDBoard08005.txt in the workspace for the detailed scope,
wire compatibility, evidence and hardware limitations.
Original R4OS code is Apache-2.0; AMD notices remain in THIRD_PARTY_NOTICES.md.
