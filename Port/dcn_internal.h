/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4AMD_DCN_INTERNAL_H
#define R4AMD_DCN_INTERNAL_H
#include "dcn_api.h"
#include "core_types.h"
#include "resource.h"
#include "hubp/dcn10/dcn10_hubp.h"
#include "hubbub/dcn10/dcn10_hubbub.h"
#include "dpp/dcn10/dcn10_dpp.h"
#include "optc/dcn10/dcn10_optc.h"
#include "opp/dcn10/dcn10_opp.h"
#include "mpc/dcn10/dcn10_mpc.h"
#include "dcn10/dcn10_ipp.h"
#include "dce/dce_aux.h"
#include "dce/dce_panel_cntl.h"
#include "dio/dcn10/dcn10_link_encoder.h"
#include "dc_bios_types.h"
#include "dce/dce_i2c_hw.h"
#include "dio/dcn10/dcn10_stream_encoder.h"
#include "ddc_service_types.h"
#include "dce/dce_clock_source.h"
#include "dce/dce_audio.h"
struct r4dcn_link {
 struct r4dcn_route route;
 struct r4dcn_atom atom;
 struct dcn10_link_encoder encoder;
 struct aux_engine_dce110 aux;
 struct dc_link link;
 struct ddc_service ddc;
 struct dc_link_settings settings;
 struct ddc gpio_ddc;
 struct dce_i2c_hw i2c;
 struct dcn10_stream_encoder stream;
 struct dce110_clk_src clock;
 struct dc_bios clock_bios;
 unsigned clock_bound,clock_attempted,clock_pipe;
 unsigned audio_bound,audio_inst,audio_configured,audio_enabled;
 unsigned i2c_ready,ddc_open,hdmi_configured,hdmi_pipe;
 unsigned dp_stream_bound,dp_configured,dp_pipe,dp_started;
 uint32_t dp_trace;
 uint32_t ddc_saved_mask;
 unsigned bound,pads_held,initialized,enabled;
 uint32_t pad_mask,hpd_mask;
};
struct r4dcn {
 struct r4dcn_io io;
 struct r4dcn_limits limits;
 uint64_t self;
 int fault;
 unsigned count,mask,prepared,programmed;
 unsigned running,tg_locked,cursor_locked;
 uint32_t dprefclk_khz;
 uint32_t fixed_disp_khz;
 struct r4dcn_mode modes[R4DCN_PIPES];
 struct dc_context ctx;
 struct dc dc;
 struct resource_pool pool;
 struct dc_state state;
 struct dcn_soc_bounding_box soc;
 struct dcn_ip_params ip;
 struct dc_stream_state streams[R4DCN_PIPES];
 struct dc_plane_state planes[R4DCN_PIPES];
 struct dcn10_hubp hubps[R4DCN_PIPES];
 struct dcn10_dpp dpps[R4DCN_PIPES];
 struct dcn10_opp opps[R4DCN_PIPES];
 struct dcn10_ipp ipps[R4DCN_PIPES];
 struct optc tgs[R4DCN_PIPES];
 struct dcn10_hubbub hubbub;
 struct dcn10_mpc mpc;
 struct dc_bios bios;
 struct r4dcn_link links[R4DCN_PIPES];
 struct dce_audio audio[4];
 struct dce_panel_cntl panel;
 unsigned panel_constructed;
};
enum bp_result r4dcn_hdmi_encoder(struct dc_bios *,struct bp_encoder_control *);
extern struct r4dcn *r4dcn_current;
int r4dcn_enter(struct r4dcn *);
void r4dcn_leave(struct r4dcn *);
#endif
