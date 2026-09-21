/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <stddef.h>
#include "v9_structs.h"
#include "../amdgpu/clearstate_defs.h"
#include "../amdgpu/clearstate_gfx9.h"
#include "../amdgpu/soc15d.h"
_Static_assert(sizeof(struct v9_mqd) == 2048, "GFX9 MQD size");
_Static_assert(sizeof(struct v9_mqd_allocation) == 2064, "GFX9 MQD tail");
_Static_assert(offsetof(struct v9_mqd_allocation, dynamic_cu_mask) == 2056, "GFX9 dynamic CU mask");
static inline uint32_t r4amd_pm4_packet(uint32_t opcode, uint32_t count) { return PACKET3(opcode, count); }
static inline void r4amd_mqd_thread_masks(struct v9_mqd *mqd) {
    mqd->compute_static_thread_mgmt_se0 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se1 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se2 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se3 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se4 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se5 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se6 = UINT32_MAX;
    mqd->compute_static_thread_mgmt_se7 = UINT32_MAX;
}
