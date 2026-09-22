# Third-Party Notices

The unchanged Linux 7.2.4 AMD sources, register headers and protocol layouts
are recorded with archive/file SHA256 and their licenses in
`ThirdParty/Sources.json`. Original bytes remain under
`ThirdParty/Linux7.2.4/Original`. The initially isolated DCN math object has
been superseded by the linked native frontend described below.

`Port/Include/os_types.h` and the module/build integration are original R4OS
code under Apache License 2.0. No third-party code is relicensed.

## AMD identity and UMA probe references (0.80.4)

The pinned Linux 7.2.4 MIT sources and register headers listed in
`ThirdParty/Sources.json` also document the read-only PCI/ASIC revision and
UMA framebuffer address rules. Their original AMD and other copyright and
permission notices remain byte-for-byte in `ThirdParty/Linux7.2.4/Original`.
These reference translation units are not linked as a Linux driver.

## ATOMBIOS and VFCT board data (0.80.5)

The original AMD MIT headers atomfirmware.h, atomfirmwareid.h, atombios.h and pptable.h
provide compiled data layouts. amdgpu_bios.c, amdgpu_atomfirmware.c,
ObjectID.h and bios_parser2.c are read-only implementation references.
These files come from the same pinned Linux 7.2.4 archive. Original
notices remain intact; paths, roles and SHA256 are in ThirdParty/Sources.json.
No x86 option-ROM code or Linux driver runtime is executed or linked.

## AMD firmware package (0.80.6)

Firmware/amdgpu contains thirteen unchanged original binaries from
linux-firmware commit 2b8daaf611fbade74f26a5b58ec1defe6a02f5e0.
Firmware/LICENSES/LICENSE.amdgpu and Firmware/WHENCE retain the original
AMD binary redistribution terms and provenance. WHENCE's historical
LICENSE.amdgpu basename refers to the preserved file under LICENSES/.
They are shipped as named R4M0 resources with the package lock. Firmware
is not relicensed, disassembled, modified or executed by the host tools.
All original file identities and metadata are in src/firmware_lock.json.

Nine additional unchanged MIT sources from Linux 7.2.4 document firmware
headers, names, RLC selection, PSP/TA, VCN/SDMA and DMCU dependencies.
Their notices and SHA256 identities are preserved in ThirdParty/Sources.json.
The format parser implements bounded reads of public container layouts;
it does not incorporate a Linux driver runtime or reverse engineer microcode.
Tools/ExportLegal.ps1 emits the complete original source notices and copies
both original firmware legal files for distribution images.

## GMC9, GFXHUB, MMHUB and ATHUB memory (0.80.7)

The additional original AMD MIT Linux 7.2.4 files and register definitions
are pinned in ThirdParty/Sources.json (46 original files in total).
memory_hubs.zig ports the relevant Picasso hub programming and invalidation
sequence from gfxhub_v1_0.c, mmhub_v1_0.c, athub_v1_0.c and gmc_v9_0.c.
The page formats, physical-address conversion and memory types follow
amdgpu_vm.h, amdgpu_vm.c, amdgpu_gmc.c and vega10_enum.h. Original complete
notices remain in the unchanged source files and in the exported
AMDGPU-SOURCE-NOTICES.txt. No Linux scheduler, TTM, DRM or runtime is linked.
The new owner, allocation, lifetime and SDK integration is R4OS code.

## IH, queues and doorbells (0.80.8)

Ten additional unchanged AMD MIT files from Linux 7.2.4 bring the original
catalog to 56 files. They cover Vega10 IH setup, IV decoding, doorbell and
source IDs, OSSSYS4 register definitions, and the direct-DMA dummy page.
queue_ih.zig ports the relevant vega10_ih.c, amdgpu_ih.c and nbio_v7_0.c
sequences and retains their full original notices in its source. All original
notices and file hashes are also exported to AMDGPU-SOURCE-NOTICES.txt.
The bounded mailbox, worker, ring accounting and canonical R4OS lifecycle
integration are original R4OS code. No Linux kernel/runtime is linked.

## PSP10 / SMU10 startup (0.80.9)

Seventeen further unchanged AMD MIT files bring Sources.json to 73 originals.
They include PSP GPCOM layouts, runtime SOC15 bases, SMU10 source/messages,
MP/PWR/SDMA4.1 registers and the DCN1 scanout register reference. The generated
constants use the actual IP_BASE instance array, including MP1's different
runtime base. start_psp, start_smu, start_engines and start_firmware port the
relevant original sequences/sections and retain complete AMD notices.
start_wire.h evaluates original C layouts without changing those originals.
All original notices and hashes are also exported into the distribution.
No Linux runtime is linked and no upstream material is relicensed.

## SDMA4.1 transfers (0.80.10)

The unchanged AMD MIT `vega10_sdma_pkt_open.h` brings the Linux source catalog
to 74 files. SDMA ring register/packet porting follows the already pinned
`sdma_v4_0.c` and NBIO7 sources; full notices remain in the originals, port
and `AMDGPU-SOURCE-NOTICES.txt`. The shared encoder additionally follows Mesa
26.2.2 `ac_cmdbuf_sdma.c/.h` and `sid.h`, pinned by R4AMD. Their AMD/Valve
copyrights and full MIT text ship as `R4AMD-NOTICES.txt` with this driver too.

## GFX9 queues and contexts (0.80.11)

The unchanged Linux AMD MIT catalog now has 81 files. Added originals cover
soc15d packets, GFX9 clear state, v9 MQD layouts, amdgpu_gfx queue definitions
and the GC9.0 register headers actually included by gfx_v9_0.c. Generated
Picasso golden tables preserve upstream masks and runtime IP_BASE offsets.
Derived ports preserve full AMD MIT grants; distribution exports include all
original notices. R4AMD also retains Mesa ac_cmdbuf_cp.c/.h (AMD 2012, Valve
2024) and the complete MIT text in R4AMD-NOTICES.txt.

## Linked image and render archive (0.80.14)

AMDGPU statically links R4AMD's sixteen original Mesa 26.2.2 AddrLib units
and three private bridges for geometry, image descriptors and GFX9 PM4
render state. The bridges derive from the unchanged Mesa originals recorded
in Libraries/R4AMD/ThirdParty/Sources.json, including radv_cmd_buffer.c and
radv_shader.c. R4AMD-NOTICES.txt exports all original AMD/Valve/other notices
and the complete MIT grant for this driver as well as the runtime library.
The six bundled shaders originate in R4OS-authored GLSL compiled by R4ACO;
their source, SPIR-V, native bytes and reproducibility hashes are preserved
in Libraries/R4AMD/Source. No additional proprietary runtime is linked.

## Linked Display Core / DCN1 (0.80.15)

The Linux catalog now contains 270 distinct unchanged files. The native
archive builds 23 original AMD DC/DCN1/DML translation units and three private
bridges. BIOS/link/protocol and newer-generation type dependencies preserve
the original layouts; unrelated generation constructors are not linked.
The sole source patch selects the original DCN1 DPP scaler and removes the
unreachable DCN2+ SPL dispatch from the copied build tree, never originals.

The AMD MIT notices remain in the original files and the derived register
tables/register helper. SPDX-only MIT headers retain their copyright
prefixes and the complete original Linux `LICENSES/preferred/MIT` text,
preserved at `ThirdParty/Linux7.2.4/LICENSES/MIT`. The original drm_dp.h has
Keith Packard's permissive grant, preserved and exported in full as well.
`Tools/ExportLegal.ps1` verifies every hash and exports all these notices to
`AMDGPU-SOURCE-NOTICES.txt`. No GPL Linux kernel primitives, DRM runtime,
scheduler, FPU switcher or device manager are linked. The private R4OS
worker, heap and MMIO adaptation is original Apache-2.0 code.

## Panel, AUX and ATOM (0.80.16)

The current catalog contains 301 unchanged originals. The linked archive
has 26 original C translation units and four R4OS bridges. Added compiled
units are dce_aux.c, dce_panel_cntl.c and dcn10_link_encoder.c. The bridge
construction and register selections retain AMD MIT notices. atom_vm.zig
and atom_opcodes.zig derive their instruction and operand semantics from
AMD's 2008 MIT atom.c and carry its full notice. There is no Linux interpreter,
GPIO service, scheduler or DRM runtime in the resulting module.

0002-aux-timeout-release.patch changes only the ordinary AUX reply timeout
in the copied build tree: a bounded loop returns the upstream timeout result
and permits release_engine. It does not swallow MMIO faults or emulate an ACK.
The original source bytes remain unchanged and both patches are catalogued.
The existing legal exporter includes all 301 source notices, the original
MIT text and unchanged firmware licenses in the Distribution.


## HDMI, clock and presentation integration (0.80.17 / 0.80.18)

The current Linux 7.2.4 catalog contains 316 unchanged, SHA256-pinned files.
The archive compiles 29 original translation units and eight private bridges.
Original dce_i2c_hw.c, dcn10_stream_encoder.c and dce_clock_source.c supply
I2C, HDMI/SST stream and pixel-clock operations. The added original clock,
HWSS, BIOS-helper and SMU10 headers retain their MIT notices and layouts.
DCN register tables, scanout/cursor calls, clock tables and stream adaptation
retain their AMD copyright and permissive notices. The two existing patches
remain confined to the generated build copy; originals are never rewritten.

The Zig presentation, transaction, BO, task and reset owners are original
Apache-2.0 code. No Linux DRM, scheduler, memory manager or runtime is linked.
The existing exporter verifies all 316 originals and exports their complete
notices, MIT grant and unchanged firmware licensing to the Distribution.
