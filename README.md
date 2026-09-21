# AMDGPU

AMDGPU is the external R4OS AMD graphics driver owner, targeting the
Picasso/Vega 8 laptop profile documented in the workspace hardware list.
Version 0.1.0 validates the driver API, reports its foundation state and
supports idempotent shutdown. It does not claim a PCI device, map registers,
load firmware, submit work or replace the boot framebuffer.

Build with `./Build.sh` on Linux or `Build.bat` on Windows. The thin starters
use the same PowerShell 7 implementation and local `Settings.R4S` mappings.
The normal build also compiles the original Linux 7.2.4 AMD DCN1 bandwidth
math dependency as a freestanding x86_64 ELF object. Clang/LLVM 19.1.7 and
the shared Libraries portability builder are required. `Build.sh test`
(or `Build.bat test`) runs the same native proof explicitly.

`ThirdParty/Sources.json` pins the exact original source and header. Their
AMD MIT notices remain intact. `Port/Include/os_types.h` only declares the
assertion dependency needed by this math file; it is not a Linux emulation
layer. The object is not linked into AMDGPU.R4D yet. Full DCN1 integration,
assert handling and SIMD-enabled worker context belong to 0.80.15.
The report under `Artifacts/Native/AMDGPU/<host>/Portability-7.2.4` records
all unresolved symbols. No success stub suppresses them.

`IMAGE_SCOPE=none` is deliberate. Device admission and graphics features
follow the AMD roadmap. Physical hardware tests belong only to 0.80.39.
Original R4OS code is Apache-2.0; see `THIRD_PARTY_NOTICES.md` for AMD code.
