/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
void r4amd_dcn_trace(unsigned, unsigned);
#define trace_dcn_optc_lock_unlock_state(optc,inst,lock,func,line) r4amd_dcn_trace(inst,lock)
#define trace_amdgpu_dm_dc_clocks_state(clocks) r4amd_dcn_trace(0,0)
