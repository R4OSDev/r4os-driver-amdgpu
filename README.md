# AMDGPU

AMDGPU is the external R4OS AMD graphics driver owner, targeting the
Picasso/Vega 8 laptop profile. Version 0.1.1 implements a bounded, read-only
identity and boot framebuffer probe for PCI 1002:15d8. It separates PCI,
subsystem and ASIC revisions; Raven2 is reported with its own IP profile
and cannot inherit Picasso initialization. Other PCI IDs remain unadmitted.

`OPTION AMDGPU mode=auto` (also the default) and `mode=passive` perform the
identity probe. `mode=native` explicitly reports that the native runtime is
not implemented. The effective kernel `GRAPHICS=SOFTWARE` policy, including
the one-shot boot-menu override, wins before PCI reads or MMIO mapping.
The driver uses the canonical PCI inventory and owner-bound UC mappings.
Only the NBIO strap/memory-size and GC framebuffer-offset registers are read.
No BAR sizing writes, bus mastering, firmware, queues or display hold is used.

Boot ownership requires the complete framebuffer span inside the measured
UMA stolen-memory range, or a matching BAR0 alias with a measured current
PCIe Resizable BAR extent. BAR0 address/size are not assumed to describe
UMA. Unknown or ambiguous ownership preserves the boot framebuffer.
Failed MMIO release retains its identity and blocks shutdown until cleanup
succeeds; shutdown remains idempotent. No native capability is advertised.

Build with `./Build.sh` on Linux or `Build.bat` on Windows. Both invoke the
same PowerShell 7 orchestration using local `Settings.R4S`. Normal builds
verify the pinned source hashes and generated register constants and run
one grouped test of the actual init/shutdown entry points with synthetic
PCI/MMIO/kernel callbacks, including policy, ownership races and cleanup.
Regenerate constants only with `Tools/VerifyIdentity.ps1 -Write`.

The build also compiles the original Linux 7.2.4 AMD DCN1 bandwidth math
dependency as a freestanding x86_64 ELF object through the shared Libraries
portability builder (Clang/LLVM 19.1.7). `Build.sh test` / `Build.bat test`
runs these same component checks explicitly. `ThirdParty/Sources.json` pins
the byte-identical MIT sources and headers. The DCN1 object is not linked
into AMDGPU.R4D yet; full display integration and its assertion/SIMD worker
contract belong to 0.80.15. Reports under
`Artifacts/Native/AMDGPU/<host>/Portability-7.2.4` list unresolved symbols.

`IMAGE_SCOPE=none` remains deliberate. Actual GPU operation follows the
AMD roadmap. Physical hardware tests belong exclusively to 0.80.39.
Original R4OS code is Apache-2.0; see `THIRD_PARTY_NOTICES.md` for AMD notices.
