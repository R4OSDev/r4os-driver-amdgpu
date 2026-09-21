// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Generated from pinned Linux 7.2.4 AMD MIT definitions. Do not hand-edit.
// Original notices and SHA256: ThirdParty/Sources.json. Tools/VerifyIdentity.ps1.
pub const nbio_base2: u32 = 0xd20;
pub const gc_base0: u32 = 0x2000;
pub const strap: u32 = (nbio_base2 + 0xf) * 4;
pub const memsize: u32 = (nbio_base2 + 0xc3) * 4;
pub const fb_offset: u32 = (gc_base0 + 0x96b) * 4;
pub const revision_mask: u32 = 0xf000000;
pub const revision_shift = 24;
pub const page_bytes: u64 = 4096;
// Required register prefix, never a measurement of the complete PCI BAR.
pub const required_prefix: u64 = 0xb000;
