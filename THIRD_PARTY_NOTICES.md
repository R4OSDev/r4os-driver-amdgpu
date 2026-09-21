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
