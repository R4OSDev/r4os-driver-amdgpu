/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#include "dcn_internal.h"
#include "dcn_register_tables.h"
#include "dml/dcn10/dcn10_fpu.h"
#include "dml/calcs/dcn_calc_auto.h"
#include "dcn10/dcn10_resource.h"
#include "asic_reg/gc/gc_9_0_sh_mask.h"
#define GB_FIELD(v,f) (((v)&GB_ADDR_CONFIG__##f##_MASK)>>GB_ADDR_CONFIG__##f##__SHIFT)
size_t r4dcn_size(void) { return sizeof(struct r4dcn); }
int r4dcn_init(void *storage,size_t bytes,const struct r4dcn_io *io,const struct r4dcn_limits *limits) {
 if (!storage || (uintptr_t)storage%16 || bytes!=sizeof(struct r4dcn) || !io || !limits ||
  !io->worker || !io->read || !io->write || !io->now_ns || !io->delay_us || !io->log || !io->fatal ||
  !io->worker(io->context) || limits->reserved || (limits->pipe_count!=3 && limits->pipe_count!=4) || limits->channels<1 || limits->channels>2 ||
  limits->ref_khz<24000 || limits->ref_khz>100000 || limits->ref_khz%1000 ||
  limits->dcf_khz<100000 || limits->dcf_khz>655000 || limits->disp_khz<100000 || limits->disp_khz>1108000 ||
  limits->dpp_khz<100000 || limits->dpp_khz>720000 || limits->fabric_khz<100000 || limits->fabric_khz>1200000 ||
  limits->soc_khz<100000 || limits->soc_khz>1200000 || limits->gb_addr_config==UINT32_MAX) return R4DCN_INVALID;
 struct r4dcn *d=storage; memset(d,0,sizeof(*d));d->io=*io;d->limits=*limits;d->self=(uintptr_t)d;
 int result=r4dcn_enter(d); if(result) return result;
 d->ctx.dc=&d->dc;d->ctx.driver_context=d;d->ctx.dce_version=limits->pipe_count==3?DCN_VERSION_1_01:DCN_VERSION_1_0;
 d->ctx.asic_id.vram_width=limits->channels*64;
 d->dc.ctx=&d->ctx;d->dc.res_pool=&d->pool;d->dc.current_state=&d->state;
 d->soc=dcn10_soc_defaults;d->ip=dcn10_ip_defaults;d->dc.dcn_soc=&d->soc;d->dc.dcn_ip=&d->ip;
 d->dc.dml.ip=dcn1_0_ip;d->dc.dml.soc=dcn1_0_soc;
 dcn10_resource_construct_fp(&d->dc);
 /* Single confirmed performance point. No implicit lower-clock DPM state. */
 d->soc.dcfclkv_min0p65=d->soc.dcfclkv_mid0p72=d->soc.dcfclkv_nom0p8=d->soc.dcfclkv_max0p9=limits->dcf_khz/1000.0f;
 d->soc.max_dispclk_vmin0p65=d->soc.max_dispclk_vmid0p72=d->soc.max_dispclk_vnom0p8=d->soc.max_dispclk_vmax0p9=limits->disp_khz/1000.0f;
 d->soc.max_dppclk_vmin0p65=d->soc.max_dppclk_vmid0p72=d->soc.max_dppclk_vnom0p8=d->soc.max_dppclk_vmax0p9=limits->dpp_khz/1000.0f;
 float bandwidth=limits->fabric_khz*limits->channels*16.0f/1000000.0f;
 d->soc.fabric_and_dram_bandwidth_vmin0p65=d->soc.fabric_and_dram_bandwidth_vmid0p72=d->soc.fabric_and_dram_bandwidth_vnom0p8=d->soc.fabric_and_dram_bandwidth_vmax0p9=bandwidth;
 d->soc.socclk=limits->soc_khz/1000.0f;
 d->dc.debug.min_disp_clk_khz=100000;d->dc.debug.optimized_watermark=true;
 d->dc.debug.pipe_split_policy=MPC_SPLIT_AVOID;d->dc.debug.disable_dmcu=true;
 d->pool.pipe_count=d->limits.pipe_count;d->pool.timing_generator_count=d->limits.pipe_count;
 d->pool.ref_clocks.dchub_ref_clock_inKhz=limits->ref_khz;
 d->pool.hubbub=&d->hubbub.base;d->pool.mpc=&d->mpc.base;
 hubbub1_construct(&d->hubbub.base,&d->ctx,&hubbub_reg,&hubbub_shift,&hubbub_mask);
 /* The shared MPC still has four slots in the original Raven2 constructor. */
 dcn10_mpc_construct(&d->mpc,&d->ctx,&mpc_regs,&mpc_shift,&mpc_mask,R4DCN_PIPES);
 for(unsigned i=0;i<d->limits.pipe_count;i++) {
  dcn10_hubp_construct(&d->hubps[i],&d->ctx,i,&hubp_regs[i],&hubp_shift,&hubp_mask);
  dpp1_construct(&d->dpps[i],&d->ctx,i,&tf_regs[i],&tf_shift,&tf_mask);
  dcn10_opp_construct(&d->opps[i],&d->ctx,i,&opp_regs[i],&opp_shift,&opp_mask);
  dcn10_ipp_construct(&d->ipps[i],&d->ctx,i,&ipp_regs[i],&ipp_shift,&ipp_mask);
  d->tgs[i].base.ctx=&d->ctx;d->tgs[i].base.inst=i;d->tgs[i].tg_regs=&tg_regs[i];d->tgs[i].tg_shift=&tg_shift;d->tgs[i].tg_mask=&tg_mask;
  dcn10_timing_generator_init(&d->tgs[i]);
  d->pool.hubps[i]=&d->hubps[i].base;d->pool.dpps[i]=&d->dpps[i].base;
  d->pool.opps[i]=&d->opps[i].base;d->pool.ipps[i]=&d->ipps[i].base;d->pool.timing_generators[i]=&d->tgs[i].base;
 }
 dcn_bw_sync_calcs_and_dml(&d->dc);
 r4dcn_leave(d);return d->fault;
}
static int mode(struct r4dcn *d,const struct r4dcn_mode *m) {
 if(m->pipe>=d->limits.pipe_count || m->flags&~31u || (m->flags&9u)==9u || ((m->flags&16u) && (!(m->flags&1u) || (m->flags&8u))) || m->width<16 || m->height<16 || m->width>4096 || m->height>4096 ||
  m->h_total>8192 || m->v_total>8192 || m->h_total<=m->width || m->v_total<=m->height ||
  !m->h_sync || !m->v_sync || !m->h_front || !m->v_front ||
  (uint64_t)m->h_front+m->h_sync>m->h_total-m->width || (uint64_t)m->v_front+m->v_sync>m->v_total-m->height ||
  m->pixel_khz<10000 || m->pixel_khz>600000 || m->pitch_bytes%256 || m->pitch_bytes<m->width*4 || m->pitch_bytes>65536 ||
  !m->mc_address || m->mc_address%256 || m->mc_address>=(1ull<<48) ||
  m->buffer_bytes<(uint64_t)m->pitch_bytes*m->height || m->buffer_bytes>(1ull<<48)-m->mc_address || d->mask&(1u<<m->pipe)) return R4DCN_INVALID;
 unsigned i=m->pipe;struct dc_stream_state *s=&d->streams[i];struct dc_plane_state *p=&d->planes[i];
 s->ctx=&d->ctx;s->signal=(m->flags&1)?SIGNAL_TYPE_HDMI_TYPE_A:SIGNAL_TYPE_EDP;
 s->phy_pix_clk=(m->flags&16)?(m->pixel_khz*5+3)/4:m->pixel_khz;
 s->timing=(struct dc_crtc_timing){.h_addressable=m->width,.v_addressable=m->height,.h_total=m->h_total,.v_total=m->v_total,
  .h_front_porch=m->h_front,.v_front_porch=m->v_front,.h_sync_width=m->h_sync,.v_sync_width=m->v_sync,
  .pix_clk_100hz=m->pixel_khz*10,.pixel_encoding=PIXEL_ENCODING_RGB,.display_color_depth=(m->flags&8)?COLOR_DEPTH_666:(m->flags&16)?COLOR_DEPTH_101010:COLOR_DEPTH_888};
 s->timing.flags.HSYNC_POSITIVE_POLARITY=!!(m->flags&2);s->timing.flags.VSYNC_POSITIVE_POLARITY=!!(m->flags&4);
 if(!optc1_validate_timing(&d->tgs[i].base,&s->timing)) return R4DCN_UNSUPPORTED;
 s->src=s->dst=(struct rect){0,0,(int)m->width,(int)m->height};
 p->ctx=&d->ctx;p->format=(m->flags&16)?SURFACE_PIXEL_FORMAT_GRPH_ARGB2101010:SURFACE_PIXEL_FORMAT_GRPH_ARGB8888;p->rotation=ROTATION_ANGLE_0;
 p->plane_size.surface_size=s->src;p->plane_size.surface_pitch=m->pitch_bytes/4;
 p->src_rect=p->dst_rect=p->clip_rect=s->src;p->visible=true;
 uint32_t gb=d->limits.gb_addr_config;
 p->tiling_info.gfx9.swizzle=DC_SW_LINEAR;p->tiling_info.gfx9.num_pipes=1u<<GB_FIELD(gb,NUM_PIPES);
 p->tiling_info.gfx9.num_banks=1u<<GB_FIELD(gb,NUM_BANKS);
 p->tiling_info.gfx9.pipe_interleave=GB_FIELD(gb,PIPE_INTERLEAVE_SIZE);
 p->tiling_info.gfx9.num_shader_engines=1u<<GB_FIELD(gb,NUM_SHADER_ENGINES);
 p->tiling_info.gfx9.num_rb_per_se=1u<<GB_FIELD(gb,NUM_RB_PER_SE);
 p->tiling_info.gfx9.max_compressed_frags=1u<<GB_FIELD(gb,MAX_COMPRESSED_FRAGS);
 p->tiling_info.gfx9.shaderEnable=1;
 p->address.type=PLN_ADDR_TYPE_GRAPHICS;p->address.grph.addr.quad_part=m->mc_address;
 struct pipe_ctx *pipe=&d->state.res_ctx.pipe_ctx[i];pipe->pipe_idx=i;pipe->stream=s;pipe->plane_state=p;
 pipe->stream_res.tg=&d->tgs[i].base;pipe->stream_res.opp=&d->opps[i].base;
 pipe->plane_res.hubp=&d->hubps[i].base;pipe->plane_res.dpp=&d->dpps[i].base;pipe->plane_res.ipp=&d->ipps[i].base;
 struct scaler_data *sc=&pipe->plane_res.scl_data;
 sc->viewport=sc->recout=sc->viewport_c=s->src;sc->h_active=m->width;sc->v_active=m->height;
 sc->ratios.horz=sc->ratios.vert=sc->ratios.horz_c=sc->ratios.vert_c=dc_fixpt_one;
 sc->taps.h_taps=sc->taps.v_taps=sc->taps.h_taps_c=sc->taps.v_taps_c=1;
 sc->format=(m->flags&16)?PIXEL_FORMAT_ARGB2101010:PIXEL_FORMAT_ARGB8888;sc->lb_params.depth=LB_PIXEL_DEPTH_30BPP;
 d->modes[i]=*m;
 d->state.streams[d->count++]=s;d->state.stream_count=d->count;d->mask|=1u<<i;
 return 0;
}
int r4dcn_prepare(void *storage,const struct r4dcn_mode *modes,uint32_t count,struct r4dcn_plan *out) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(d->fault || d->programmed || !modes || !out || !count || count>d->limits.pipe_count) { r4dcn_leave(d);return R4DCN_STATE; }
 d->prepared=0;d->count=d->mask=0;memset(&d->state,0,sizeof(d->state));memset(d->streams,0,sizeof(d->streams));memset(d->planes,0,sizeof(d->planes));
 d->state.bw_ctx.dml=d->dc.dml;
 for(unsigned i=0;i<count && !result;i++)result=mode(d,&modes[i]);
 /* Validate first, before the upstream algorithm may allocate split pipes.
  * This initial owner admits one unscaled RGB plane per hardware pipe. */
 if(!result && !dcn_validate_bandwidth(&d->dc,&d->state,DC_VALIDATE_MODE_ONLY))result=R4DCN_BANDWIDTH;
 for(unsigned i=0;i<count && !result;i++)if(d->state.dcn_bw_vars.dpp_per_plane[i]!=1)result=R4DCN_UNSUPPORTED;
 if(!result && !dcn_validate_bandwidth(&d->dc,&d->state,DC_VALIDATE_MODE_AND_PROGRAMMING))result=R4DCN_BANDWIDTH;
 if(!result) {
  const struct dc_clocks *c=&d->state.bw_ctx.bw.dcn.clk;
  const struct dcn_watermarks *w=&d->state.bw_ctx.bw.dcn.watermarks.a;
  *out=(struct r4dcn_plan){.count=d->count,.pipe_mask=d->mask,.disp_khz=c->dispclk_khz,.dpp_khz=c->dppclk_khz,
   .dcf_khz=c->dcfclk_khz,.fabric_khz=c->fclk_khz,.urgent_ns=w->urgent_ns,.pte_ns=w->pte_meta_urgent_ns,
   .stutter_exit_ns=w->cstate_pstate.cstate_exit_ns,.stutter_enter_exit_ns=w->cstate_pstate.cstate_enter_plus_exit_ns,
   .pstate_ns=w->cstate_pstate.pstate_change_ns,.voltage_level=d->state.dcn_bw_vars.voltage_level};
  d->prepared=1;
 }
 r4dcn_leave(d);return result;
}
static bool frontend_quiet(struct r4dcn *d,unsigned i) {
 return r4dcn_frontend_quiet(d,i,!(d->mask&(1u<<i)),NULL);
}
static void program_pipe(struct r4dcn *d,unsigned i) {
  struct pipe_ctx *p=&d->state.res_ctx.pipe_ctx[i];struct hubp *h=&d->hubps[i].base;
  optc1_enable_optc_clock(&d->tgs[i].base,true);hubp1_clk_cntl(h,true);hubp1_vtg_sel(h,i);
  if(d->fault)return;
  const struct dc_clocks *clocks=&d->state.bw_ctx.bw.dcn.clk;
  dpp1_dppclk_control(&d->dpps[i].base,!d->fixed_disp_khz && clocks->dppclk_khz<=clocks->dispclk_khz/2,true);
  opp1_pipe_clock_control(&d->opps[i].base,true);
  optc1_program_timing(&d->tgs[i].base,&p->stream->timing,p->pipe_dlg_param.vready_offset,p->pipe_dlg_param.vstartup_start,
   p->pipe_dlg_param.vupdate_offset,p->pipe_dlg_param.vupdate_width,0,p->stream->signal,false);
  hubp1_program_requestor(h,&p->rq_regs);hubp1_program_deadline(h,&p->dlg_regs,&p->ttu_regs);
  hubp1_program_surface_config(h,p->plane_state->format,&p->plane_state->tiling_info,&p->plane_state->plane_size,
   ROTATION_ANGLE_0,&p->plane_state->dcc,false,0);
  min_set_viewport(h,&p->plane_res.scl_data.viewport,&p->plane_res.scl_data.viewport_c);
  d->dpps[i].base.funcs->dpp_full_bypass(&d->dpps[i].base);
  /* Original bypass assumes ARGB8888. Keep CM bypass, set the actual CNVC format. */
  dpp1_cnv_setup(&d->dpps[i].base,p->plane_state->format,0,(struct dc_csc_transform){0},COLOR_SPACE_SRGB,NULL);
  dpp1_dscl_set_scaler_manual_scale(&d->dpps[i].base,&p->plane_res.scl_data);
  struct mpc_tree *tree=&d->opps[i].base.mpc_tree_params;
  *tree=(struct mpc_tree){.opp_id=i};
  struct mpcc_blnd_cfg blend={.alpha_mode=MPCC_ALPHA_BLEND_MODE_GLOBAL_ALPHA,.global_alpha=255,.global_gain=255};
  struct mpcc_sm_cfg stereo={0};
  if(!mpc1_insert_plane(&d->mpc.base,tree,&blend,&stereo,NULL,i,i))d->fault=R4DCN_STATE;
  mpc1_set_bg_color(&d->mpc.base,&blend.black_color,i);
  struct bit_depth_reduction_params depth={0};
  depth.flags.TRUNCATE_ENABLED=p->stream->timing.display_color_depth!=COLOR_DEPTH_101010;depth.flags.TRUNCATE_DEPTH=p->stream->timing.display_color_depth==COLOR_DEPTH_666?0:1;
  struct clamping_and_pixel_encoding_params clamp={.clamping_level=CLAMPING_FULL_RANGE,.pixel_encoding=PIXEL_ENCODING_RGB};
  opp1_program_fmt(&d->opps[i].base,&depth,&clamp);
  opp1_set_dyn_expansion(&d->opps[i].base,COLOR_SPACE_SRGB,p->stream->timing.display_color_depth,p->stream->signal);
  if(!hubp1_program_surface_flip_and_addr(h,&p->plane_state->address,true))d->fault=R4DCN_IO;
 }
int r4dcn_program(void *storage) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!d->prepared || d->programmed || d->fault) { r4dcn_leave(d);return R4DCN_STATE; }
 /* Watermarks and MPC are shared. Selected pipes must be stopped and blank;
  * unused pipes may instead be confirmed fully power-gated. */
 for(unsigned i=0;i<d->limits.pipe_count;i++) {
  if(!frontend_quiet(d,i))result=R4DCN_STATE;
 }
 if(result || d->fault) { r4dcn_leave(d);return d->fault?d->fault:result; }
 d->programmed=1;
 mpc1_mpc_init(&d->mpc.base);
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)mpc1_assert_idle_mpcc(&d->mpc.base,i);
 hubbub1_program_watermarks(&d->hubbub.base,&d->state.bw_ctx.bw.dcn.watermarks,d->limits.ref_khz/1000,false);
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)if(d->mask&(1u<<i))program_pipe(d,i);
 r4dcn_leave(d);return d->fault;
}
/* No clock change while a peer is scanning. Fixed full-rate DPP is a
 * conservative initial policy; dynamic power transitions own later lowering. */
int r4dcn_fixed_clock(void *storage,uint32_t khz) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(d->fault || khz<100000 || khz>d->limits.disp_khz || khz>d->limits.dpp_khz)result=R4DCN_INVALID;
 for(unsigned i=0;!result && i<d->limits.pipe_count;i++)if(!frontend_quiet(d,i))result=R4DCN_STATE;
 if(!result && !d->fault)d->fixed_disp_khz=khz;
 r4dcn_leave(d);return d->fault?d->fault:result;
}
static void unlink_pipe(struct r4dcn *d,unsigned i) {
 struct mpc_tree *tree=&d->opps[i].base.mpc_tree_params;
 if(tree->opp_list)mpc1_remove_mpcc(&d->mpc.base,tree,tree->opp_list);
 mpc1_assert_idle_mpcc(&d->mpc.base,i);
}
int r4dcn_remove(void *storage,uint32_t pipe) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(pipe>=d->limits.pipe_count || !d->programmed || d->fault || !(d->mask&(1u<<pipe)) ||
  (d->running&(1u<<pipe)) || !frontend_quiet(d,pipe))result=R4DCN_STATE;
 if(!result && !d->fault) {
  unlink_pipe(d,pipe);
  if(!d->fault) {
   d->mask&=~(1u<<pipe);d->count=0;
   memset(d->state.streams,0,sizeof(d->state.streams));
   for(unsigned i=0;i<d->limits.pipe_count;i++)if(d->mask&(1u<<i))d->state.streams[d->count++]=&d->streams[i];
   d->state.stream_count=d->count;
  }
 }
 r4dcn_leave(d);return d->fault?d->fault:result;
}
int r4dcn_update(void *storage,const void *candidate,uint32_t pipe) {
 struct r4dcn *d=storage;const struct r4dcn *n=candidate;
 int result=r4dcn_enter(d);if(result)return result;
 if(!n || n==d || n->self!=(uintptr_t)n || !n->prepared || n->programmed || n->fault ||
  !d->prepared || !d->programmed || d->fault || !d->fixed_disp_khz || pipe>=d->limits.pipe_count ||
  !(n->mask&(1u<<pipe)) || (d->running&(1u<<pipe)) ||
  (n->mask&~(1u<<pipe))!=(d->mask&~(1u<<pipe)) || memcmp(&d->limits,&n->limits,sizeof(d->limits)))result=R4DCN_STATE;
 if(!result && (n->state.bw_ctx.bw.dcn.clk.dispclk_khz>d->fixed_disp_khz ||
  n->state.bw_ctx.bw.dcn.clk.dppclk_khz>d->fixed_disp_khz))result=R4DCN_BANDWIDTH;
 if(!result && !frontend_quiet(d,pipe))result=R4DCN_STATE;
 /* An unrelated timing/address change must never ride along this update.
  * Pending peer flips keep their own request address and receipt. */
 for(unsigned i=0;!result && i<d->limits.pipe_count;i++)if(i!=pipe && (d->mask&(1u<<i))) {
  if(memcmp(&d->modes[i],&n->modes[i],sizeof(struct r4dcn_mode)))result=R4DCN_STATE;
  uint32_t lock=dm_read_reg(&d->ctx,tg_regs[i].OTG_MASTER_UPDATE_LOCK);
  if(lock&(tg_mask.OTG_MASTER_UPDATE_LOCK|tg_mask.UPDATE_LOCK_STATUS) ||
   ((d->tg_locked|d->cursor_locked)&(1u<<i)))result=R4DCN_BUSY;
 }
 if(result || d->fault) { r4dcn_leave(d);return d->fault?d->fault:result; }
 if(d->mask&(1u<<pipe))unlink_pipe(d,pipe);
 /* Copy only calculated values, never candidate-context pointers or MPC
  * state. The peer's active plane, address and cursor are untouched. */
 d->mask&=~(1u<<pipe);d->count=0;
 memset(&d->streams[pipe],0,sizeof(d->streams[pipe]));memset(&d->planes[pipe],0,sizeof(d->planes[pipe]));
 memset(&d->state.res_ctx.pipe_ctx[pipe],0,sizeof(struct pipe_ctx));
 result=mode(d,&n->modes[pipe]);
 d->count=0;
 for(unsigned i=0;i<d->limits.pipe_count;i++)if(d->mask&(1u<<i)) {
  d->state.streams[d->count++]=&d->streams[i];
  struct pipe_ctx *p=&d->state.res_ctx.pipe_ctx[i];const struct pipe_ctx *q=&n->state.res_ctx.pipe_ctx[i];
  p->rq_regs=q->rq_regs;p->dlg_regs=q->dlg_regs;p->ttu_regs=q->ttu_regs;p->pipe_dlg_param=q->pipe_dlg_param;
 }
 d->state.stream_count=d->count;d->state.bw_ctx.bw.dcn=n->state.bw_ctx.bw.dcn;
 hubbub1_program_watermarks(&d->hubbub.base,&d->state.bw_ctx.bw.dcn.watermarks,d->limits.ref_khz/1000,false);
 for(unsigned i=0;i<d->limits.pipe_count && !d->fault;i++)if(i!=pipe && (d->running&(1u<<i))) {
  struct pipe_ctx *p=&d->state.res_ctx.pipe_ctx[i];struct timing_generator *tg=&d->tgs[i].base;
  d->tg_locked|=1u<<i;optc1_lock(tg);
  hubp1_program_requestor(&d->hubps[i].base,&p->rq_regs);
  hubp1_program_deadline(&d->hubps[i].base,&p->dlg_regs,&p->ttu_regs);
  tg->funcs->program_global_sync(tg,p->pipe_dlg_param.vready_offset,p->pipe_dlg_param.vstartup_start,
   p->pipe_dlg_param.vupdate_offset,p->pipe_dlg_param.vupdate_width,0);
  optc1_unlock(tg);if(!d->fault)d->tg_locked&=~(1u<<i);
 }
 if(!result && !d->fault)program_pipe(d,pipe);
 r4dcn_leave(d);return d->fault?d->fault:result;
}
int r4dcn_quiesce(void *storage) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 /* A retry can observe late idle, but never silently acknowledge a timeout. */
 d->fault=0;
 for(unsigned i=0;i<d->limits.pipe_count;i++) {
  if(!frontend_quiet(d,i))result=R4DCN_STATE;
 }
 if(!result && !d->fault) { d->programmed=0;d->running=0; }
 r4dcn_leave(d);return d->fault?d->fault:result;
}
int r4dcn_fault(const void *storage) { return ((const struct r4dcn*)storage)->fault; }
void r4dcn_destroy(void *storage) { struct r4dcn *d=storage;ASSERT(!d->programmed);d->self=0; }
