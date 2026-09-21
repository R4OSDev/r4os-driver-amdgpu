/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4_AMD_START_WIRE_H
#define R4_AMD_START_WIRE_H
#include <stdint.h>
#include <stddef.h>
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/amdgpu/psp_gfx_if.h"
/* Evaluate original bitfield-containing layouts in Clang, never approximate
 * their ABI with a translated Zig opaque type. Wire words are little endian. */
enum {
 R4_PSP_COMMAND_BYTES = sizeof(struct psp_gfx_cmd_resp),
 R4_PSP_COMMAND_ID = offsetof(struct psp_gfx_cmd_resp, cmd_id),
 R4_PSP_ARGUMENTS = offsetof(struct psp_gfx_cmd_resp, cmd),
 R4_PSP_RESPONSE = offsetof(struct psp_gfx_cmd_resp, resp),
 R4_PSP_RESPONSE_BYTES = sizeof(struct psp_gfx_resp),
 R4_PSP_FRAME_BYTES = sizeof(struct psp_gfx_rb_frame),
 R4_PSP_FRAME_FENCE = offsetof(struct psp_gfx_rb_frame, fence_addr_lo),
 R4_PSP_FRAME_TOKEN = offsetof(struct psp_gfx_rb_frame, fence_value),
 R4_PSP_TMR_FLAGS = offsetof(struct psp_gfx_cmd_setup_tmr, tmr_flags),
 R4_PSP_TMR_PHYSICAL = offsetof(struct psp_gfx_cmd_setup_tmr, system_phy_addr_lo),
 R4_PSP_FW_TYPE = offsetof(struct psp_gfx_cmd_load_ip_fw, fw_type)
};
_Static_assert(R4_PSP_COMMAND_BYTES == 1024 && R4_PSP_COMMAND_ID == 8 && R4_PSP_ARGUMENTS == 28, "PSP command ABI");
_Static_assert(R4_PSP_RESPONSE == 864 && R4_PSP_RESPONSE_BYTES == 96, "PSP response ABI");
_Static_assert(R4_PSP_FRAME_BYTES == 64 && R4_PSP_FRAME_FENCE == 12 && R4_PSP_FRAME_TOKEN == 20, "PSP ring ABI");
_Static_assert(R4_PSP_TMR_FLAGS == 12 && R4_PSP_TMR_PHYSICAL == 16 && R4_PSP_FW_TYPE == 12, "PSP argument ABI");
#endif
