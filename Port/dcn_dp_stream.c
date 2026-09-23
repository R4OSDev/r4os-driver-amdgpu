/*
 * Copyright 2012-15 Advanced Micro Devices, Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 * Authors: AMD
 *
 */
/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
/* Original DCN1 SST stream functions; the owner supplies bounded route,
 * timing, trained-link and frontend admission. No DPCD test mode is enabled. */
#include "dcn_internal.h"
#include "dcn_hdmi_tables.h"
#include "link_service.h"
static struct r4dcn_link *edp(struct r4dcn *d,unsigned i) {
 return i<4 && d->links[i].bound && (d->links[i].route.connector&255)==0x14?&d->links[i]:NULL;
}
static void trace(struct dc_link *link,uint8_t sequence) {
 struct r4dcn_link *l=container_of(link,struct r4dcn_link,link);
 l->dp_trace=sequence;
}
/* The original functions use only the source-sequence diagnostic callback.
 * Other link-service operations are deliberately absent from this owner. */
static struct link_service link_service={.dp_trace_source_sequence=trace};
static uint32_t rd(struct r4dcn *d,uint32_t reg){return dm_read_reg(&d->ctx,reg);}
int r4dcn_dp_stream_bind(void *storage,uint32_t index) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=edp(d,index);
 if(!l || l->dp_stream_bound || d->fault)result=R4DCN_STATE;
 else {
  d->dc.link_srv=&link_service;
  dcn10_stream_encoder_construct(&l->stream,&d->ctx,&d->bios,ENGINE_ID_DIGA+l->route.phy,
   &stream_enc_regs[l->route.phy],&se_shift,&se_mask);
  l->dp_stream_bound=1;
 }
 r4dcn_leave(d);return result;
}
int r4dcn_dp_stream_configure(void *storage,uint32_t index,uint32_t pipe,uint32_t bpc) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=edp(d,index);
 if(!l || !l->dp_stream_bound || !l->initialized || !d->prepared || pipe>=d->limits.pipe_count || !(d->mask&(1u<<pipe)) || d->fault)result=R4DCN_STATE;
 else if((bpc!=6 && bpc!=8) || d->streams[pipe].signal!=SIGNAL_TYPE_EDP ||
  d->streams[pipe].timing.display_color_depth!=(bpc==6?COLOR_DEPTH_666:COLOR_DEPTH_888))result=R4DCN_INVALID;
 else if(l->enabled || dcn10_is_dig_enabled(&l->encoder.base) ||
  rd(d,tg_regs[pipe].OTG_CONTROL)&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE) ||
  rd(d,l->stream.regs->DP_VID_STREAM_CNTL)&(se_mask.DP_VID_STREAM_ENABLE|se_mask.DP_VID_STREAM_STATUS))result=R4DCN_STATE;
 else if(!d->fault) {
  l->dp_configured=0;l->dp_pipe=pipe;
  struct stream_encoder *enc=&l->stream.base;
  dcn10_link_encoder_setup(&l->encoder.base,SIGNAL_TYPE_EDP);
  enc->funcs->dig_connect_to_otg(enc,pipe);
  enc->funcs->dp_set_stream_attribute(enc,&d->streams[pipe].timing,COLOR_SPACE_SRGB,false,0);
  enc->funcs->stop_dp_info_packets(enc);
  enc->funcs->dp_audio_disable(enc);
  if(!d->fault)l->dp_configured=1;
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_dp_stream_start(void *storage,uint32_t index) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=edp(d,index);
 if(!l || !l->dp_configured || !l->enabled || l->dp_started || !d->programmed || d->fault)result=R4DCN_STATE;
 else if(!dcn10_is_dig_enabled(&l->encoder.base) ||
  !(rd(d,tg_regs[l->dp_pipe].OTG_CONTROL)&tg_mask.OTG_CURRENT_MASTER_EN_STATE) ||
  rd(d,l->stream.regs->DP_VID_STREAM_CNTL)&(se_mask.DP_VID_STREAM_ENABLE|se_mask.DP_VID_STREAM_STATUS))result=R4DCN_STATE;
 else if(!d->fault) {
  struct encoder_unblank_param params={.link_settings=l->settings,.timing=d->streams[l->dp_pipe].timing,.opp_cnt=1,.pix_per_cycle=1};
  l->dp_started=1; /* Unknown partial submission remains owned until stop. */
  l->stream.base.funcs->dp_unblank(&l->link,&l->stream.base,&params);
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_dp_stream_stop(void *storage,uint32_t index) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=edp(d,index);
 if(!l || !l->dp_stream_bound)result=R4DCN_STATE;
 else {
  /* Cleanup may recover a transient MMIO fault. Every read/write and the
   * original bounded stream-status wait must succeed again on this attempt. */
  d->fault=0;
  l->stream.base.funcs->dp_blank(&l->link,&l->stream.base);
  uint32_t status=rd(d,l->stream.regs->DP_VID_STREAM_CNTL);
  if(status&(se_mask.DP_VID_STREAM_ENABLE|se_mask.DP_VID_STREAM_STATUS))result=R4DCN_BUSY;
  else if(!d->fault) {
   /* A previous wait may have timed out after clearing ENABLE. Upstream's
    * next call returns early in that case; finish the FIFO reset only after
    * STATUS has actually retired. */
   dm_write_reg(&d->ctx,l->stream.regs->DP_STEER_FIFO,rd(d,l->stream.regs->DP_STEER_FIFO)|se_mask.DP_STEER_FIFO_RESET);
   if(!d->fault)l->dp_started=0;
  }
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
