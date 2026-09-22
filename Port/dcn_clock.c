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
/* Internal-reference RGB8 subset of command_table2.c:set_pixel_clock_v7.
 * PLL/DTO decisions and deep-color resync use the original clock source TU. */
#include "dcn_internal.h"
#include "dcn_clock_tables.h"
#include "atomfirmware.h"
#include "ObjectID.h"
static enum bp_result pixel_clock(struct dc_bios *bios,struct bp_pixel_clock_parameters *p) {
 struct r4dcn *d=bios->ctx->driver_context;
 struct r4dcn_link *l=container_of(bios,struct r4dcn_link,clock_bios);
 if(!l->clock_bound || p->controller_id<CONTROLLER_ID_D0 || p->controller_id>CONTROLLER_ID_D3 ||
  p->target_pixel_clock_100hz<100000 || p->target_pixel_clock_100hz>6000000 ||
  (p->signal_type!=SIGNAL_TYPE_EDP && p->signal_type!=SIGNAL_TYPE_HDMI_TYPE_A) ||
  p->flags.SET_GENLOCK_REF_DIV_SRC || p->flags.SUPPORT_YUV_420)return BP_RESULT_BADINPUT;
 struct set_pixel_clock_parameter_v1_7 command={0};
 command.pixclk_100hz=p->target_pixel_clock_100hz;
 command.crtc_id=p->controller_id-CONTROLLER_ID_D0;
 command.encoder_mode=p->signal_type==SIGNAL_TYPE_HDMI_TYPE_A?ATOM_ENCODER_MODE_HDMI:ATOM_ENCODER_MODE_DP;
 command.deep_color_ratio=0; /* RGB8, no deep-color ratio. */
 if(p->pll_id==CLOCK_SOURCE_ID_DP_DTO && p->signal_type==SIGNAL_TYPE_EDP)command.pll_id=ATOM_DP_DTO;
 else if(p->pll_id==CLOCK_SOURCE_COMBO_PHY_PLL0+l->route.phy && p->signal_type==SIGNAL_TYPE_HDMI_TYPE_A)
  command.pll_id=ATOM_COMBOPHY_PLL0+l->route.phy;
 else return BP_RESULT_BADINPUT;
 switch(p->encoder_object_id.id) {
  case ENCODER_ID_INTERNAL_UNIPHY:command.encoderobjid=ENCODER_OBJECT_ID_INTERNAL_UNIPHY;break;
  case ENCODER_ID_INTERNAL_UNIPHY1:command.encoderobjid=ENCODER_OBJECT_ID_INTERNAL_UNIPHY1;break;
  default:return BP_RESULT_BADINPUT;
 }
 uint32_t words[sizeof(command)/4];memcpy(words,&command,sizeof(command));
 unsigned index=offsetof(struct atom_master_list_of_command_functions_v2_1,setpixelclock)/2;
 if(d->fault || l->atom.execute(l->atom.context,index,words,ARRAY_SIZE(words))) { d->fault=R4DCN_IO;return BP_RESULT_FAILURE; }
 return BP_RESULT_OK;
}
static const struct dc_vbios_funcs clock_bios_functions={.set_pixel_clock=pixel_clock};
int r4dcn_reference_clock_program(void *storage,uint32_t index,uint32_t *actual_khz) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(index>=4 || !d->links[index].bound || !actual_khz || d->fault)result=R4DCN_STATE;
 for(unsigned i=0;!result && i<4;i++)
  if(dm_read_reg(&d->ctx,tg_regs[i].OTG_CONTROL)&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE))result=R4DCN_STATE;
 if(!result && !d->fault) {
  /* dce112_set_dprefclk / command_table2:set_dce_clock_v2_1. Firmware
   * chooses DPREFCLK; zero target is intentional, never an assumed 600MHz. */
  struct set_dce_clock_ps_allocation_v2_1 command={.param={.dceclktype=DCE_CLOCK_TYPE_DPREFCLK,.dceclksrc=ATOM_GCK_DFS}};
  uint32_t words[sizeof(command)/4];memcpy(words,&command,sizeof(command));
  struct r4dcn_link *l=&d->links[index];l->clock_attempted=1;d->dprefclk_khz=0;
  unsigned cmd=offsetof(struct atom_master_list_of_command_functions_v2_1,setdceclock)/2;
  if(l->atom.execute(l->atom.context,cmd,words,ARRAY_SIZE(words)))d->fault=R4DCN_IO;
  else if(words[0]<2400 || words[0]>120000)result=R4DCN_IO;
  else { d->dprefclk_khz=words[0]*10;*actual_khz=d->dprefclk_khz; }
 }
 r4dcn_leave(d);return d->fault?d->fault:result;
}
int r4dcn_pixel_clock_bind(void *storage,uint32_t index,uint32_t crystal_khz) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(index>=4 || !d->links[index].bound || d->links[index].clock_bound || d->fault ||
  crystal_khz<24000 || crystal_khz>100000 || crystal_khz%10)result=R4DCN_INVALID;
 else {
  struct r4dcn_link *l=&d->links[index];bool hdmi=(l->route.connector&255)==0x0c;
  if(!hdmi && (l->route.connector&255)!=0x14)result=R4DCN_UNSUPPORTED;
  else {
   /* This constructor consumes only external_clock_source_frequency_for_dp.
    * The admitted board path uses the internal reference, so no external clock
    * is advertised. The complete Linux BIOS parser is not represented here. */
   l->clock_bios.ctx=&d->ctx;l->clock_bios.funcs=&clock_bios_functions;
   l->clock_bios.fw_info.pll_info.crystal_frequency=crystal_khz;
   l->clock_bios.fw_info.external_clock_source_frequency_for_dp=0;
   l->clock_bios.fw_info_valid=true;
   enum clock_source_id id=hdmi?CLOCK_SOURCE_COMBO_PHY_PLL0+l->route.phy:CLOCK_SOURCE_ID_DP_DTO;
   if(dce112_clk_src_construct(&l->clock,&d->ctx,&l->clock_bios,id,&clk_src_regs[l->route.phy],&cs_shift,&cs_mask))l->clock_bound=1;
   else result=R4DCN_STATE;
  }
 }
 r4dcn_leave(d);return d->fault?d->fault:result;
}
int r4dcn_pixel_clock_program(void *storage,uint32_t index,uint32_t pipe) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(index>=4 || pipe>=4 || !d->links[index].clock_bound || !d->dprefclk_khz || !d->prepared || !(d->mask&(1u<<pipe)) || d->fault)
  result=R4DCN_STATE;
 else {
  struct r4dcn_link *l=&d->links[index];struct dc_stream_state *s=&d->streams[pipe];
  uint32_t ctl=dm_read_reg(&d->ctx,tg_regs[pipe].OTG_CONTROL);
  if(l->enabled || dcn10_is_dig_enabled(&l->encoder.base) ||
   ctl&(tg_mask.OTG_MASTER_EN|tg_mask.OTG_CURRENT_MASTER_EN_STATE) ||
   (s->signal==SIGNAL_TYPE_HDMI_TYPE_A)!=((l->route.connector&255)==0x0c))result=R4DCN_STATE;
  else if(!d->fault) {
   struct pixel_clk_params params={.requested_pix_clk_100hz=s->timing.pix_clk_100hz,.signal_type=s->signal,
    .controller_id=CONTROLLER_ID_D0+pipe,.color_depth=s->timing.display_color_depth,.encoder_object_id=l->encoder.base.id};
   struct pll_settings pll={.actual_pix_clk_100hz=s->timing.pix_clk_100hz,.use_external_clk=false};
   l->clock_attempted=1;l->clock_pipe=pipe;
   if(!l->clock.base.funcs->program_pix_clk(&l->clock.base,&params,DP_8b_10b_ENCODING,&pll))result=R4DCN_IO;
  }
 }
 r4dcn_leave(d);return d->fault?d->fault:result;
}
