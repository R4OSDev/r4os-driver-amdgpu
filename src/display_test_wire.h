/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#define __maybe_unused __attribute__((unused))
#include "vega10_ip_offset.h"
#include "asic_reg/dcn/dcn_1_0_offset.h"
#include "asic_reg/dcn/dcn_1_0_sh_mask.h"
#define R4DCN_TG_CLOCK_0 ((DCE_BASE__INST0_SEG2 + mmOTG0_OTG_CLOCK_CONTROL)*4)
#define R4DCN_INPUT_CLOCK_0 ((DCE_BASE__INST0_SEG2 + mmODM0_OPTC_INPUT_CLOCK_CONTROL)*4)
#define R4DCN_MPC_STATUS(i) ((DCE_BASE__INST0_SEG2 + mmMPCC0_MPCC_STATUS + (i)*(mmMPCC1_MPCC_STATUS-mmMPCC0_MPCC_STATUS))*4)
#define R4DCN_MPC_MUX_0 ((DCE_BASE__INST0_SEG2 + mmMPC_OUT0_MUX)*4)
