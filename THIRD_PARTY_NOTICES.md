# Third-Party Notices

`ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/display/dc/dml/calcs/dcn_calc_math.c`
and `dc/inc/dcn_calc_math.h` are unmodified AMD source from Linux 7.2.4.
Copyright 2017 Advanced Micro Devices, Inc. Both files contain the complete
MIT permission and disclaimer. Exact URLs, archive/file SHA-256 and scope
are recorded in `ThirdParty/Sources.json`. No other Linux implementation
is compiled in this foundation. The native object is not in AMDGPU.R4D yet.

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
