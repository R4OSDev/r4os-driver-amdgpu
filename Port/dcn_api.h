/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4AMD_DCN_API_H
#define R4AMD_DCN_API_H
#include <stddef.h>
#include <stdint.h>
/* Private R4D boundary. Every entry is called by the dedicated SIMD display
 * task. No upstream DC structure, float or callback enters the platform ABI. */
#define R4DCN_PIPES 4
enum r4dcn_result { R4DCN_OK=0, R4DCN_INVALID=-1, R4DCN_BANDWIDTH=-2,
 R4DCN_IO=-3, R4DCN_TIMEOUT=-4, R4DCN_STATE=-5, R4DCN_UNSUPPORTED=-6 };
struct r4dcn_io {
 void *context;
 int (*read)(void *, uint32_t byte_offset, uint32_t *value);
 int (*write)(void *, uint32_t byte_offset, uint32_t value);
 uint64_t (*now_ns)(void *);
 int (*delay_us)(void *, uint32_t);
 int (*worker)(void *);
 void (*log)(void *, const char *);
 void (*fatal)(void *, const char *, const char *, unsigned);
};
struct r4dcn_mode {
 uint32_t width,height,h_total,v_total,h_front,h_sync,v_front,v_sync;
 uint32_t pixel_khz,pitch_bytes,pipe,flags; /* flags: bit0 HDMI, bit1/2 positive H/V sync */
 uint64_t mc_address,buffer_bytes;
};
struct r4dcn_limits {
 /* Fixed DCF/fabric/SOC clocks, DISP/DPP ceilings, in kHz. Commit must confirm
  * the plan's actual DISPCLK and DPP divider. Channels come from the parsed
  * board. A reference bounding box is never hardware evidence. */
 uint32_t channels,dcf_khz,disp_khz,dpp_khz,fabric_khz,soc_khz,ref_khz;
 uint32_t gb_addr_config,reserved;
};
struct r4dcn_plan {
 uint32_t count,pipe_mask,disp_khz,dpp_khz,dcf_khz,fabric_khz;
 uint32_t urgent_ns,pte_ns,stutter_exit_ns,stutter_enter_exit_ns,pstate_ns;
 uint32_t voltage_level;
};
size_t r4dcn_size(void);
int r4dcn_init(void *, size_t, const struct r4dcn_io *, const struct r4dcn_limits *);
int r4dcn_prepare(void *, const struct r4dcn_mode *, uint32_t, struct r4dcn_plan *);
/* Program only disabled/blanked DCN1 frontends after the owner has confirmed
 * clock, memory and link preparation. Output enable/pageflip belongs to /18. */
int r4dcn_program(void *);
int r4dcn_quiesce(void *);
int r4dcn_fault(const void *);
void r4dcn_destroy(void *);
#endif
