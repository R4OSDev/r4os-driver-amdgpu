/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4_DISPLAY_CLOCK_WIRE_H
#define R4_DISPLAY_CLOCK_WIRE_H
#include <stdint.h>
#include <stddef.h>
#ifndef __maybe_unused
#define __maybe_unused __attribute__((unused))
#endif
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/include/vega10_ip_offset.h"
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/pm/powerplay/inc/smu10.h"
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/pm/powerplay/inc/smu10_driver_if.h"
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/pm/powerplay/inc/rv_ppsmc.h"
_Static_assert(sizeof(DpmClock_t)==8 && sizeof(DpmClocks_t)==160, "SMU10 DPM clock table ABI");
_Static_assert(offsetof(DpmClocks_t,SocClocks)==32 && offsetof(DpmClocks_t,FClocks)==96 && offsetof(DpmClocks_t,MemClocks)==128,"SMU10 clock offsets");
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/include/asic_reg/thm/thm_9_0_offset.h"
#include "../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/include/asic_reg/thm/thm_9_0_sh_mask.h"
#endif
