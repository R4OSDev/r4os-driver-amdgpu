/*
 * Copyright 2016 Advanced Micro Devices, Inc.
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
/* Original DCN1 HUBP/OPTC/MPC/DPP methods with bounded R4D admission. Cursor
 * routing follows dcn10_hwseq (one unscaled RGB plane, no split or rotation).
 * All addresses below are MC addresses of retained, GPU-visible UMA BOs. */
#include "dcn_internal.h"
#include "dcn_register_tables.h"
static uint32_t rd(struct r4dcn *d,uint32_t reg) { return dm_read_reg(&d->ctx,reg); }
static unsigned field(uint32_t v,uint32_t mask,unsigned shift) { return (v&mask)>>shift; }
static int admitted(struct r4dcn *d,unsigned pipe) {
 return pipe<d->limits.pipe_count && d->prepared && d->programmed && (d->mask&(1u<<pipe)) && !d->fault;
}
static int finish(struct r4dcn *d,int result) { int fault=d->fault;r4dcn_leave(d);return fault?fault:result; }
static bool running(struct r4dcn *d,unsigned pipe) {
 uint32_t ctl=rd(d,tg_regs[pipe].OTG_CONTROL);
 return (ctl&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE))==
  (tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE);
}
int r4dcn_scanout_enable(void *storage,uint32_t pipe) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!admitted(d,pipe) || (d->running&(1u<<pipe)))return finish(d,R4DCN_STATE);
 struct timing_generator *tg=&d->tgs[pipe].base;
 if(rd(d,tg_regs[pipe].OTG_MASTER_UPDATE_LOCK)&(tg_mask.OTG_MASTER_UPDATE_LOCK|tg_mask.UPDATE_LOCK_STATUS))
  return finish(d,R4DCN_BUSY);
 if(rd(d,tg_regs[pipe].OTG_CONTROL)&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE))
  return finish(d,R4DCN_STATE);
 /* Retain before any partial enable. The caller waits for running + matching
  * in-use BO + counter progress; enable_crtc returning true is not a receipt. */
 d->running|=1u<<pipe;
 /* An inherited boot cursor is not owned by our new cursor-image lifetime. */
 d->hubps[pipe].base.funcs->hubp_disconnect(&d->hubps[pipe].base);
 dm_write_reg(&d->ctx,tf_regs[pipe].CURSOR0_CONTROL,rd(d,tf_regs[pipe].CURSOR0_CONTROL)&~tf_mask.CUR0_ENABLE);
 tg->funcs->tg_init(tg);
 if(!tg->funcs->enable_crtc(tg))return finish(d,R4DCN_IO);
 hubp1_set_blank(&d->hubps[pipe].base,false);
 optc1_set_blank(tg,false);
 return finish(d,0);
}
static int stop_pipes(struct r4dcn *d,uint32_t mask) {
 int result=0;
 /* Recovery may retry failed writes. It never clears fault and frees memory
  * without observing stopped TG, blank HUBP and no outstanding memory reads. */
 d->fault=0;
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)if(mask&(1u<<i)) {
  struct timing_generator *tg=&d->tgs[i].base;
  if(d->tg_locked&(1u<<i)) { optc1_unlock(tg);if(!d->fault)d->tg_locked&=~(1u<<i); }
  if(d->cursor_locked&(1u<<i)) { mpc1_cursor_lock(&d->mpc.base,i,false);if(!d->fault)d->cursor_locked&=~(1u<<i); }
  optc1_set_blank(tg,true);
  d->hubps[i].base.funcs->hubp_disconnect(&d->hubps[i].base);
  dm_write_reg(&d->ctx,tf_regs[i].CURSOR0_CONTROL,rd(d,tf_regs[i].CURSOR0_CONTROL)&~tf_mask.CUR0_ENABLE);
  d->dpps[i].base.pos.cur0_ctl.bits.cur0_enable=0;
  d->dpps[i].base.att.cur0_ctl.bits.cur0_enable=0;
  hubp1_set_blank(&d->hubps[i].base,true);
  optc1_disable_crtc(tg);
  uint32_t ctl=rd(d,tg_regs[i].OTG_CONTROL),hub=rd(d,hubp_regs[i].DCHUBP_CNTL);
  uint32_t required=hubp_mask.HUBP_BLANK_EN|hubp_mask.HUBP_IN_BLANK|hubp_mask.HUBP_NO_OUTSTANDING_REQ;
  if((ctl&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE)) || (hub&required)!=required)
   result=R4DCN_BUSY;
  else if(!d->fault)d->running&=~(1u<<i);
 }
 return finish(d,result);
}
int r4dcn_scanout_stop(void *storage,uint32_t mask) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!d->programmed || !mask || (mask&~d->mask))return finish(d,R4DCN_STATE);
 return stop_pipes(d,mask);
}
bool r4dcn_frontend_quiet(struct r4dcn *d,unsigned i,bool allow_gated,struct r4dcn_inherited_probe *probe) {
 static const uint32_t pg_status[]={
  BASE(mmDOMAIN0_PG_STATUS_BASE_IDX)+mmDOMAIN0_PG_STATUS,
  BASE(mmDOMAIN2_PG_STATUS_BASE_IDX)+mmDOMAIN2_PG_STATUS,
  BASE(mmDOMAIN4_PG_STATUS_BASE_IDX)+mmDOMAIN4_PG_STATUS,
  BASE(mmDOMAIN6_PG_STATUS_BASE_IDX)+mmDOMAIN6_PG_STATUS};
 if(i>=d->limits.pipe_count || d->fault)return false;
 uint32_t ctl=rd(d,tg_regs[i].OTG_CONTROL);
 if(probe) { probe->checked_mask|=1u<<i;probe->control[i]=ctl; }
 if(d->fault || (ctl&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE)))return false;
 uint32_t hub=rd(d,hubp_regs[i].DCHUBP_CNTL);
 if(probe)probe->hubp[i]=hub;
 if(d->fault)return false;
 if(hub&hubp_mask.HUBP_IN_BLANK)return true;
 if(!allow_gated)return false;
 /* dcn10_hubp_pg_control: HUBP0..3 are domains0/2/4/6 and PGFSM_POWER_OFF
  * is exactly2. A powered-off unused domain need not assert IN_BLANK.
  * Never infer idle from a stopped TG alone, reset/disable, or a transition.
  * Selected pipes still require the original blank receipt before writes. */
 uint32_t power=rd(d,pg_status[i]);
 if(probe) { probe->power_mask|=1u<<i;probe->power[i]=power; }
 return !d->fault && field(power,DOMAIN0_PG_STATUS__DOMAIN0_PGFSM_PWR_STATUS_MASK,
  DOMAIN0_PG_STATUS__DOMAIN0_PGFSM_PWR_STATUS__SHIFT)==2;
}
int r4dcn_inherited_stop(void *storage) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!d->prepared)return finish(d,R4DCN_STATE);
 /* Unused frontends were admitted as already quiet. Do not write into
  * unrelated, potentially power-gated HUBP/DPP instances. */
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)if(!(d->mask&(1u<<i))) {
  if(!r4dcn_frontend_quiet(d,i,true,NULL))return finish(d,R4DCN_STATE);
 }
 return stop_pipes(d,d->mask);
}
int r4dcn_inherited_admit(void *storage,struct r4dcn_inherited_probe *probe) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(probe) { memset(probe,0,sizeof(*probe));probe->rejected_pipe=UINT32_MAX; }
 if(!d->prepared || d->programmed || d->fault)return finish(d,R4DCN_STATE);
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)if(!(d->mask&(1u<<i))) {
  if(!r4dcn_frontend_quiet(d,i,true,probe)) {
   if(probe)probe->rejected_pipe=i;
   return finish(d,R4DCN_UNSUPPORTED);
  }
 }
 return finish(d,0);
}
int r4dcn_scanout_sample(void *storage,uint32_t pipe,struct r4dcn_scanout_sample *output) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!output || !admitted(d,pipe))return finish(d,R4DCN_STATE);
 struct timing_generator *tg=&d->tgs[pipe].base;
 /* A frame boundary can tear the position/address observation. Retry without
  * publishing any of that partial sample. No repeated polling within a call. */
 for(unsigned attempt=0;attempt<3 && !d->fault;attempt++) {
  struct r4dcn_scanout_sample s={0};struct crtc_position pos;
  s.begin_ns=d->io.now_ns(d->io.context);
  s.frame=optc1_get_vblank_counter(tg);
  optc1_get_position(tg,&pos);s.hpos=pos.horizontal_count;s.vpos=pos.vertical_count;
  s.requested_address=d->hubps[pipe].base.request_address.grph.addr.quad_part;
  uint32_t high=rd(d,hubp_regs[pipe].DCSURF_SURFACE_EARLIEST_INUSE_HIGH);
  uint32_t low=rd(d,hubp_regs[pipe].DCSURF_SURFACE_EARLIEST_INUSE);
  uint32_t high2=rd(d,hubp_regs[pipe].DCSURF_SURFACE_EARLIEST_INUSE_HIGH);
  s.inuse_address=((uint64_t)field(high,hubp_mask.SURFACE_EARLIEST_INUSE_ADDRESS_HIGH,hubp_shift.SURFACE_EARLIEST_INUSE_ADDRESS_HIGH)<<32) |
   field(low,hubp_mask.SURFACE_EARLIEST_INUSE_ADDRESS,hubp_shift.SURFACE_EARLIEST_INUSE_ADDRESS);
  s.pending=hubp1_is_flip_pending(&d->hubps[pipe].base);
  s.running=running(d,pipe);
  uint32_t hub=rd(d,hubp_regs[pipe].DCHUBP_CNTL),blank=rd(d,tg_regs[pipe].OTG_BLANK_CONTROL);
  s.blank=!!((hub&(hubp_mask.HUBP_BLANK_EN|hubp_mask.HUBP_IN_BLANK|hubp_mask.HUBP_DISABLE)) ||
   (blank&(tg_mask.OTG_BLANK_DATA_EN|tg_mask.OTG_CURRENT_BLANK_STATE)));
  s.underflow=!!(hub&hubp_mask.HUBP_UNDERFLOW_STATUS) || tg->funcs->is_optc_underflow_occurred(tg);
  s.locked=!!(rd(d,tg_regs[pipe].OTG_MASTER_UPDATE_LOCK)&(tg_mask.OTG_MASTER_UPDATE_LOCK|tg_mask.UPDATE_LOCK_STATUS));
  s.locked|=!!((d->tg_locked|d->cursor_locked)&(1u<<pipe));
  s.locked|=!!(rd(d,mpc_regs.CUR[pipe])&mpc_mask.CUR_VUPDATE_LOCK_SET);
  s.cursor_address=((uint64_t)field(rd(d,hubp_regs[pipe].CURSOR_SURFACE_ADDRESS_HIGH),hubp_mask.CURSOR_SURFACE_ADDRESS_HIGH,hubp_shift.CURSOR_SURFACE_ADDRESS_HIGH)<<32) |
   field(rd(d,hubp_regs[pipe].CURSOR_SURFACE_ADDRESS),hubp_mask.CURSOR_SURFACE_ADDRESS,hubp_shift.CURSOR_SURFACE_ADDRESS);
  uint32_t xy=rd(d,hubp_regs[pipe].CURSOR_POSITION),hot=rd(d,hubp_regs[pipe].CURSOR_HOT_SPOT),size=rd(d,hubp_regs[pipe].CURSOR_SIZE);
  s.cursor_x=field(xy,hubp_mask.CURSOR_X_POSITION,hubp_shift.CURSOR_X_POSITION);
  s.cursor_y=field(xy,hubp_mask.CURSOR_Y_POSITION,hubp_shift.CURSOR_Y_POSITION);
  s.cursor_hot_x=field(hot,hubp_mask.CURSOR_HOT_SPOT_X,hubp_shift.CURSOR_HOT_SPOT_X);
  s.cursor_hot_y=field(hot,hubp_mask.CURSOR_HOT_SPOT_Y,hubp_shift.CURSOR_HOT_SPOT_Y);
  s.cursor_width=field(size,hubp_mask.CURSOR_WIDTH,hubp_shift.CURSOR_WIDTH);
  s.cursor_height=field(size,hubp_mask.CURSOR_HEIGHT,hubp_shift.CURSOR_HEIGHT);
  s.cursor_enabled=!!(rd(d,hubp_regs[pipe].CURSOR_CONTROL)&hubp_mask.CURSOR_ENABLE);
  s.cursor_dpp_enabled=!!(rd(d,tf_regs[pipe].CURSOR0_CONTROL)&tf_mask.CUR0_ENABLE);
  uint32_t after=optc1_get_vblank_counter(tg);s.end_ns=d->io.now_ns(d->io.context);
  if(d->fault)break;
  if(s.end_ns<s.begin_ns)return finish(d,R4DCN_IO);
  if(after==s.frame && high==high2) { *output=s;return finish(d,0); }
 }
 return finish(d,R4DCN_BUSY);
}
int r4dcn_scanout_flip(void *storage,uint32_t pipe,uint64_t address,uint64_t bytes) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!admitted(d,pipe) || !(d->running&(1u<<pipe)))return finish(d,R4DCN_STATE);
 const struct dc_plane_state *p=&d->planes[pipe];
 if(!address || address%256 || address>=(1ull<<48) || bytes>(1ull<<48)-address ||
  bytes<(uint64_t)p->plane_size.surface_pitch*4*p->plane_size.surface_size.height)return finish(d,R4DCN_INVALID);
 if(!running(d,pipe) || hubp1_in_blank(&d->hubps[pipe].base))return finish(d,R4DCN_STATE);
 if(hubp1_is_flip_pending(&d->hubps[pipe].base) ||
  (rd(d,tg_regs[pipe].OTG_MASTER_UPDATE_LOCK)&(tg_mask.OTG_MASTER_UPDATE_LOCK|tg_mask.UPDATE_LOCK_STATUS)))return finish(d,R4DCN_BUSY);
 d->tg_locked|=1u<<pipe;
 optc1_lock(&d->tgs[pipe].base);
 struct dc_plane_address next=p->address;next.grph.addr.quad_part=address;
 if(!d->fault && !hubp1_program_surface_flip_and_addr(&d->hubps[pipe].base,&next,false))result=R4DCN_IO;
 optc1_unlock(&d->tgs[pipe].base);
 if(!d->fault)d->tg_locked&=~(1u<<pipe);
 return finish(d,result);
}
/* The DCN1 cursor erratum forbids taking the MPC cursor lock near VUPDATE.
 * Restrict admission to the interior of the observed active picture, with
 * the upstream 70us guard on either edge. Busy is retried by the worker. */
static bool cursor_window(struct r4dcn *d,unsigned pipe) {
 const struct dc_crtc_timing *t=&d->streams[pipe].timing;
 uint32_t v=rd(d,tg_regs[pipe].OTG_V_BLANK_START_END);
 uint32_t start=field(v,tg_mask.OTG_V_BLANK_START,tg_shift.OTG_V_BLANK_START);
 uint32_t end=field(v,tg_mask.OTG_V_BLANK_END,tg_shift.OTG_V_BLANK_END);
 struct crtc_position p;optc1_get_position(&d->tgs[pipe].base,&p);
 uint32_t lines=((uint64_t)70*t->pix_clk_100hz+9999*t->h_total)/(10000*t->h_total)+1;
 return end<start && start<=t->v_total && p.vertical_count>=end+lines &&
  p.vertical_count+lines<start && running(d,pipe);
}
int r4dcn_scanout_cursor(void *storage,uint32_t pipe,const struct r4dcn_cursor *input) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!input || !admitted(d,pipe) || !(d->running&(1u<<pipe)))return finish(d,R4DCN_STATE);
 const struct r4dcn_cursor *v=input;
 if(v->enable>1 || (v->enable && (!v->mc_address || v->mc_address%256 || v->mc_address>=(1ull<<48) ||
  v->buffer_bytes>(1ull<<48)-v->mc_address || !v->width || !v->height || v->width>64 || v->height>64 ||
  v->pitch_pixels!=64 || v->buffer_bytes<64*4*v->height || v->hot_x>=v->width || v->hot_y>=v->height)))return finish(d,R4DCN_INVALID);
 if((rd(d,mpc_regs.CUR[pipe])&mpc_mask.CUR_VUPDATE_LOCK_SET) ||
  (rd(d,tg_regs[pipe].OTG_MASTER_UPDATE_LOCK)&(tg_mask.OTG_MASTER_UPDATE_LOCK|tg_mask.UPDATE_LOCK_STATUS)) ||
  !cursor_window(d,pipe))return finish(d,R4DCN_BUSY);
 const struct dc_crtc_timing *t=&d->streams[pipe].timing;
 int64_t left=(int64_t)v->x-v->hot_x,top=(int64_t)v->y-v->hot_y;
 bool visible=v->enable && left<(int64_t)t->h_addressable && top<(int64_t)t->v_addressable &&
  left+(int64_t)v->width>0 && top+(int64_t)v->height>0;
 struct dc_cursor_position pos={.enable=visible};
 if(visible) {
  pos.x=left<0?0:left;pos.y=top<0?0:top;
  pos.x_hotspot=left<0?-left:0;pos.y_hotspot=top<0?-top:0;
 }
 struct dc_cursor_mi_param param={.pixel_clk_khz=t->pix_clk_100hz/10,.ref_clk_khz=d->limits.ref_khz,
  .viewport=d->planes[pipe].src_rect,.h_scale_ratio=dc_fixpt_one,.v_scale_ratio=dc_fixpt_one,
  .rotation=ROTATION_ANGLE_0,.stream=&d->streams[pipe]};
 d->cursor_locked|=1u<<pipe;mpc1_cursor_lock(&d->mpc.base,pipe,true);
 if(v->enable) {
  struct dc_cursor_attributes attr={.address.quad_part=v->mc_address,.pitch=64,.width=v->width,.height=v->height,
   .color_format=CURSOR_MODE_COLOR_PRE_MULTIPLIED_ALPHA};
  hubp1_cursor_set_attributes(&d->hubps[pipe].base,&attr);dpp1_set_cursor_attributes(&d->dpps[pipe].base,&attr);
 }
 hubp1_cursor_set_position(&d->hubps[pipe].base,&pos,&param);
 dpp1_set_cursor_position(&d->dpps[pipe].base,&pos,&param,d->hubps[pipe].base.curs_attr.width,d->hubps[pipe].base.curs_attr.height);
 mpc1_cursor_lock(&d->mpc.base,pipe,false);
 if(!d->fault)d->cursor_locked&=~(1u<<pipe);
 return finish(d,0);
}
