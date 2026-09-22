/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4AMD_DCN_API_H
#define R4AMD_DCN_API_H
#include <stddef.h>
#include <stdint.h>
/* Private R4D boundary. Every entry is called by the dedicated SIMD display
 * task. No upstream DC structure, float or callback enters the platform ABI. */
#define R4DCN_PIPES 4
enum r4dcn_result { R4DCN_OK=0, R4DCN_INVALID=-1, R4DCN_BANDWIDTH=-2,
 R4DCN_IO=-3, R4DCN_TIMEOUT=-4, R4DCN_STATE=-5, R4DCN_UNSUPPORTED=-6,
 R4DCN_BUSY=-7 };
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
 uint32_t pixel_khz,pitch_bytes,pipe,flags; /* bit0 HDMI, bit1/2 positive H/V, bit3 RGB6 eDP */
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
/* Confirmed fixed clock, full-rate DPP. Set only while every TG is stopped.
 * A live update consumes an independently prepared joint DML candidate;
 * only the changed, stopped head is reprogrammed. */
int r4dcn_fixed_clock(void *,uint32_t actual_disp_khz);
int r4dcn_update(void *,const void *candidate,uint32_t changed_pipe);
int r4dcn_remove(void *,uint32_t pipe);
int r4dcn_quiesce(void *);
int r4dcn_fault(const void *);
void r4dcn_destroy(void *);
/* Private connector interface. Route addresses are DWORD register indices
 * from validated board GPIO records; bind verifies them against DCN1. */
struct r4dcn_route {
 uint32_t connector,encoder,phy,aux,hpd,caps;
 uint32_t ddc_a,hpd_a,hpd_shift,hpd_active;
};
struct r4dcn_atom {
 void *context;
 int (*execute)(void *,uint32_t command,uint32_t *parameters,uint32_t words);
};
struct r4dcn_aux {
 uint32_t address,length,flags; /* bit0 read, bit1 I2C, bit2 MOT, bit3 status request */
 uint8_t data[16];
 uint32_t reply,transferred,status;
};
struct r4dcn_panel_state {
 uint32_t powered,lit,pwm_valid,firmware_busy,pwm,period;
};
enum r4dcn_link_action { R4DCN_LINK_INIT=0,R4DCN_PANEL_ON,R4DCN_PANEL_OFF,
 R4DCN_BACKLIGHT_ON,R4DCN_BACKLIGHT_OFF,R4DCN_LINK_DISABLE };
int r4dcn_link_bind(void *,uint32_t,const struct r4dcn_route *,const struct r4dcn_atom *);
int r4dcn_link_action(void *,uint32_t,uint32_t);
int r4dcn_link_aux(void *,uint32_t,struct r4dcn_aux *);
int r4dcn_link_enable(void *,uint32_t,uint32_t rate,uint32_t lanes,uint32_t spread);
int r4dcn_link_train(void *,uint32_t,uint32_t pattern,const uint8_t lane_settings[4]);
int r4dcn_link_hpd(void *,uint32_t,uint32_t *);
int r4dcn_link_restore_pads(void *,uint32_t);
int r4dcn_panel_read(void *,struct r4dcn_panel_state *);
int r4dcn_panel_pwm(void *,uint32_t);
int r4dcn_link_video(void *,uint32_t,uint32_t pipe,uint32_t *);
/* SST eDP RGB6/8 stream. Enable is submission; link_video plus scanout
 * counter/address progress supplies the surrounding visibility proof. */
int r4dcn_dp_stream_bind(void *,uint32_t);
int r4dcn_dp_stream_configure(void *,uint32_t,uint32_t pipe,uint32_t bpc);
int r4dcn_dp_stream_start(void *,uint32_t);
int r4dcn_dp_stream_stop(void *,uint32_t);
/* Direct HDMI1.4 RGB8 path. Reference crystal is parsed from ATOM DCE info;
 * DDC block reads use the original DCN hardware I2C engine. */
int r4dcn_hdmi_bind(void *,uint32_t,uint32_t crystal_khz);
int r4dcn_hdmi_edid(void *,uint32_t,uint32_t block,uint8_t data[128]);
int r4dcn_hdmi_configure(void *,uint32_t,uint32_t pipe,const uint8_t avi[17]);
int r4dcn_hdmi_enable(void *,uint32_t);
int r4dcn_hdmi_mute(void *,uint32_t,uint32_t mute);
int r4dcn_hdmi_stopped(void *,uint32_t,uint32_t *stopped);
int r4dcn_hdmi_active(void *,uint32_t,uint32_t pipe,uint32_t *active);
/* Native scanout. Timestamps bound a coherent register observation; they are
 * NOT an interrupt timestamp or the instant at which a pixel was displayed.
 * The frame counter is the original 24-bit OTG counter, including rollover. */
struct r4dcn_scanout_sample {
 uint64_t begin_ns,end_ns,requested_address,inuse_address;
 uint32_t frame,hpos,vpos,running,blank,pending,underflow,locked;
 uint64_t cursor_address;
 uint32_t cursor_x,cursor_y,cursor_hot_x,cursor_hot_y,cursor_width,cursor_height,cursor_enabled,cursor_dpp_enabled;
};
struct r4dcn_cursor {
 uint64_t mc_address,buffer_bytes;
 uint32_t width,height,pitch_pixels,hot_x,hot_y,enable;
 int32_t x,y;
};
int r4dcn_scanout_enable(void *,uint32_t pipe);
/* Stop retains clocks and the plan. Link/clock restoration is still owned by
 * the surrounding transaction; only confirmed idle permits releasing BOs. */
int r4dcn_scanout_stop(void *,uint32_t pipe_mask);
/* Held boot ownership is required by the caller. Stops inherited frontends
 * before the first native programming; all device allocations remain pinned. */
int r4dcn_inherited_stop(void *);
int r4dcn_inherited_admit(void *);
int r4dcn_scanout_sample(void *,uint32_t pipe,struct r4dcn_scanout_sample *);
int r4dcn_scanout_flip(void *,uint32_t pipe,uint64_t mc_address,uint64_t bytes);
int r4dcn_scanout_cursor(void *,uint32_t pipe,const struct r4dcn_cursor *);
/* Original DCN1 pixel-clock programming over the board's ATOM 1.7 command.
 * Bind has no MMIO effects; program requires the selected TG and DIG stopped. */
int r4dcn_pixel_clock_bind(void *,uint32_t link,uint32_t crystal_khz);
int r4dcn_reference_clock_program(void *,uint32_t link,uint32_t *actual_khz);
int r4dcn_reference_clock_get(void *,uint32_t *actual_khz);
int r4dcn_pixel_clock_program(void *,uint32_t link,uint32_t pipe);
#endif
