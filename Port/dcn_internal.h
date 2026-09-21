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
struct r4dcn {
 struct r4dcn_io io;
 struct r4dcn_limits limits;
 uint64_t self;
 int fault;
 unsigned count,mask,prepared,programmed;
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
};
extern struct r4dcn *r4dcn_current;
int r4dcn_enter(struct r4dcn *);
void r4dcn_leave(struct r4dcn *);
#endif
