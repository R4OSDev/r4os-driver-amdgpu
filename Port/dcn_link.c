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
/* Bounded embedded-object bridge to the original DCN1 link/AUX/PWM code. */
#include "dcn_internal.h"
#include "dcn_link_tables.h"
#include "stream_encoder.h"
#include "atomfirmware.h"
#include "atom.h"

#define ADDR(reg) (BASE(mm##reg##_BASE_IDX)+mm##reg)
static const uint32_t ddc_a[4]={ADDR(DC_GPIO_DDC1_A),ADDR(DC_GPIO_DDC2_A),ADDR(DC_GPIO_DDC3_A),ADDR(DC_GPIO_DDC4_A)};
static const uint32_t ddc_mask[4]={ADDR(DC_GPIO_DDC1_MASK),ADDR(DC_GPIO_DDC2_MASK),ADDR(DC_GPIO_DDC3_MASK),ADDR(DC_GPIO_DDC4_MASK)};
static const unsigned hpd_shift[4]={DC_GPIO_HPD_A__DC_GPIO_HPD1_A__SHIFT,DC_GPIO_HPD_A__DC_GPIO_HPD2_A__SHIFT,DC_GPIO_HPD_A__DC_GPIO_HPD3_A__SHIFT,DC_GPIO_HPD_A__DC_GPIO_HPD4_A__SHIFT};
static uint32_t rd(struct r4dcn *d,uint32_t reg) { return dm_read_reg_func(&d->ctx,reg,__func__); }
static void wr(struct r4dcn *d,uint32_t reg,uint32_t value) { dm_write_reg_func(&d->ctx,reg,value,__func__); }
static struct graphics_object_id object(uint32_t raw) {
 return (struct graphics_object_id){.id=raw&255,.enum_id=(raw>>8)&15,.type=(raw>>12)&7};
}
static struct r4dcn_link *link_at(struct r4dcn *d,unsigned index) {
 return index<4 && d->links[index].bound ? &d->links[index] : NULL;
}
static enum bp_result transmitter(struct dc_bios *bios,struct bp_transmitter_control *ctl) {
 struct r4dcn *d=bios->ctx->driver_context;
 struct r4dcn_link *l=NULL;
 for(unsigned i=0;i<4;i++) if(d->links[i].bound && d->links[i].encoder.base.transmitter==ctl->transmitter) l=&d->links[i];
 if(!l || d->fault) return BP_RESULT_FAILURE;
 /* Revision 1.6 is admitted by the ATOM owner before binding. All reserved
  * parameters stay zero; no Linux BIOS parser or DMUB command path is used. */
 struct dig_transmitter_control_ps_allocation_v1_6 p={0};
 p.param.phyid=l->route.phy;
 p.param.action=ctl->action;
 if(ctl->action==TRANSMITTER_CONTROL_SET_VOLTAGE_AND_PREEMPASIS) p.param.mode_laneset.dplaneset=ctl->lane_settings;
 else if(ctl->signal==SIGNAL_TYPE_HDMI_TYPE_A) p.param.mode_laneset.digmode=ATOM_ENCODER_MODE_HDMI;
 else if(ctl->signal==SIGNAL_TYPE_EDP || dc_is_dp_signal(ctl->signal)) p.param.mode_laneset.digmode=ATOM_ENCODER_MODE_DP;
 else if(ctl->signal!=SIGNAL_TYPE_NONE) return BP_RESULT_UNSUPPORTED;
 p.param.lanenum=ctl->lanes_number;
 p.param.hpdsel=l->route.hpd+1;
 p.param.digfe_sel=ctl->engine_id>=ENGINE_ID_DIGA && ctl->engine_id<=ENGINE_ID_DIGD ? 1u<<(ctl->engine_id-ENGINE_ID_DIGA):0;
 p.param.connobj_id=l->route.connector&255;
 p.param.symclk_10khz=ctl->pixel_clock/10;
 uint32_t words[sizeof(p)/4];memcpy(words,&p,sizeof(p));
 unsigned command=offsetof(struct atom_master_list_of_command_functions_v2_1,dig1transmittercontrol)/2;
 if(l->atom.execute(l->atom.context,command,words,ARRAY_SIZE(words))!=0) { d->fault=R4DCN_IO; return BP_RESULT_FAILURE; }
 return BP_RESULT_OK;
}
static const struct dc_vbios_funcs bios_functions={.transmitter_control=transmitter,.encoder_control=r4dcn_hdmi_encoder};
static const struct link_encoder_funcs link_functions={.is_dig_enabled=dcn10_is_dig_enabled};
int r4dcn_link_bind(void *storage,uint32_t index,const struct r4dcn_route *route,const struct r4dcn_atom *atom) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!route || !atom || !atom->execute || index>=4 || route->phy>=4 || route->aux>=4 || route->hpd>=4 ||
    route->ddc_a!=ddc_a[route->aux] || route->hpd_a!=ADDR(DC_GPIO_HPD_A) || route->hpd_shift!=hpd_shift[route->hpd] ||
    route->hpd_active>1 || route->connector>65535 || (route->connector&0x7000)!=0x3000 ||
    route->encoder>65535 || (route->encoder&0x7000)!=0x2000 || d->links[index].bound || d->fault) result=R4DCN_INVALID;
 for(unsigned i=0;!result && i<4;i++) if(d->links[i].bound && (d->links[i].route.phy==route->phy || d->links[i].route.aux==route->aux)) result=R4DCN_STATE;
 if(!result) {
  struct r4dcn_link *l=&d->links[index];l->route=*route;l->atom=*atom;l->bound=1;
  d->bios.ctx=&d->ctx;d->bios.funcs=&bios_functions;d->ctx.dc_bios=&d->bios;
  /* Embedded equivalent of the DC constructor: only the original routines
   * used here are exposed, so there is no heap destructor/GPIO service. */
  struct dcn10_link_encoder *e=&l->encoder;
  e->base.ctx=&d->ctx;e->base.id=object(route->encoder);e->base.connector=object(route->connector);
  e->base.id.id=route->phy<2?ENCODER_ID_INTERNAL_UNIPHY:ENCODER_ID_INTERNAL_UNIPHY1;
  e->base.transmitter=TRANSMITTER_UNIPHY_A+route->phy;e->base.preferred_engine=ENGINE_ID_DIGA+route->phy;
  e->base.hpd_source=HPD_SOURCEID1+route->hpd;e->base.funcs=&link_functions;
  e->base.features.flags.bits.IS_HBR2_CAPABLE=!!(route->caps&ATOM_ENCODER_CAP_RECORD_HBR2_EN);
  e->base.features.flags.bits.IS_HBR3_CAPABLE=!!(route->caps&ATOM_ENCODER_CAP_RECORD_HBR3_EN);
  e->base.features.flags.bits.HDMI_6GB_EN=!!(route->caps&ATOM_ENCODER_CAP_RECORD_HDMI6Gbps_EN);
  e->link_regs=&link_enc_regs[route->phy];e->aux_regs=&link_enc_aux_regs[route->aux];e->hpd_regs=&link_enc_hpd_regs[route->hpd];
  e->link_shift=&le_shift;e->link_mask=&le_mask;
  d->pool.engines[route->aux]=dce110_aux_engine_construct(&l->aux,&d->ctx,route->aux,2400,&aux_engine_regs[route->aux],&aux_mask,&aux_shift,false);
  l->link.ctx=&d->ctx;l->link.dc=&d->dc;l->link.aux_hw_inst=route->aux;
  l->ddc.ctx=&d->ctx;l->ddc.link=&l->link;
  if(!d->panel_constructed) {
   struct panel_cntl_init_data init={.ctx=&d->ctx,.inst=0};
   dce_panel_cntl_construct(&d->panel,&init,&panel_cntl_regs[0],&panel_cntl_shift,&panel_cntl_mask);d->panel_constructed=1;
  }
 }
 r4dcn_leave(d);return result;
}
int r4dcn_link_action(void *storage,uint32_t index,uint32_t action) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!l || action>R4DCN_LINK_DISABLE || d->fault) result=R4DCN_STATE;
 else if(action==R4DCN_LINK_INIT) {
  if(!l->pads_held) {
   l->pad_mask=rd(d,ddc_mask[l->route.aux]);l->hpd_mask=rd(d,ADDR(DC_GPIO_HPD_MASK));
   if(!d->fault) {
    l->pads_held=1;
    if((l->route.connector&255)==0x14) wr(d,ddc_mask[l->route.aux],(l->pad_mask&~(DC_GPIO_DDC1_MASK__DC_GPIO_DDC1CLK_MASK_MASK|DC_GPIO_DDC1_MASK__DC_GPIO_DDC1DATA_MASK_MASK))|DC_GPIO_DDC1_MASK__AUX_PAD1_MODE_MASK);
    wr(d,ADDR(DC_GPIO_HPD_MASK),l->hpd_mask&~(1u<<l->route.hpd_shift));
   }
  }
  if(!d->fault) dcn10_link_encoder_hw_init(&l->encoder.base);
  if(!d->fault) l->initialized=1;
 } else if(action==R4DCN_LINK_DISABLE) {
  /* Upstream skips an inactive DIG. A partially enabled PHY still needs
   * its explicit ATOM disable even if DIG never became active. */
  if(l->enabled && !dcn10_is_dig_enabled(&l->encoder.base)) {
   struct bp_transmitter_control ctl={.action=TRANSMITTER_CONTROL_DISABLE,
    .transmitter=l->encoder.base.transmitter,.signal=(l->route.connector&255)==0x0c?SIGNAL_TYPE_HDMI_TYPE_A:SIGNAL_TYPE_EDP};
   if(!d->fault) transmitter(&d->bios,&ctl);
  }
  if(!d->fault) dcn10_link_encoder_disable_output(&l->encoder.base,(l->route.connector&255)==0x0c?SIGNAL_TYPE_HDMI_TYPE_A:SIGNAL_TYPE_EDP);
  if(!d->fault) l->enabled=0;
 } else if((l->route.connector&255)!=0x14) result=R4DCN_UNSUPPORTED;
 else {
  static const enum bp_transmitter_control_action actions[]={0,TRANSMITTER_CONTROL_POWER_ON,TRANSMITTER_CONTROL_POWER_OFF,TRANSMITTER_CONTROL_BACKLIGHT_ON,TRANSMITTER_CONTROL_BACKLIGHT_OFF};
  struct bp_transmitter_control ctl={.action=actions[action],.engine_id=ENGINE_ID_UNKNOWN,.transmitter=l->encoder.base.transmitter,
   .connector_obj_id=l->encoder.base.connector,.lanes_number=LANE_COUNT_FOUR,.hpd_sel=l->encoder.base.hpd_source,.signal=SIGNAL_TYPE_EDP};
  if(transmitter(&d->bios,&ctl)!=BP_RESULT_OK) result=R4DCN_IO;
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_link_aux(void *storage,uint32_t index,struct r4dcn_aux *packet) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!packet || !l || !l->initialized || d->fault) result=R4DCN_STATE;
 else if(packet->address>0xfffff || packet->length>16 || packet->flags&~15u ||
   ((packet->flags&2) && packet->address>0x7f) || (!(packet->flags&2) && (!packet->length || packet->flags&12)) ||
   ((packet->flags&8) && packet->length)) result=R4DCN_INVALID;
 else {
  uint8_t reply=0xff;enum aux_return_code_type status;
  struct aux_payload p={.address=packet->address,.length=packet->length,.data=packet->data,.reply=&reply,
   .write=!(packet->flags&1),.i2c_over_aux=!!(packet->flags&2),.mot=!!(packet->flags&4),.write_status_update=!!(packet->flags&8)};
  int count=dce_aux_transfer_raw_without_ddc_pin(&l->ddc,&p,&status);
  packet->reply=reply;packet->status=status;packet->transferred=count<0?0:(unsigned)count;
  if(d->fault)result=d->fault;
  else if(count<0)result=status==AUX_RET_ERROR_TIMEOUT?R4DCN_TIMEOUT:R4DCN_IO;
  else if(count>16 || (reply==0 && !p.write && !p.write_status_update && count>(int)p.length))result=R4DCN_IO;
 }
 r4dcn_leave(d);return result;
}
int r4dcn_link_enable(void *storage,uint32_t index,uint32_t rate,uint32_t lanes,uint32_t spread) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!l || !l->initialized || d->fault || (lanes!=1 && lanes!=2 && lanes!=4) || spread!=0 ||
  (rate!=6 && rate!=10 && rate!=20 && rate!=30)) result=R4DCN_INVALID;
 else if((rate>=20 && !(l->route.caps&ATOM_ENCODER_CAP_RECORD_HBR2_EN)) || (rate==30 && !(l->route.caps&ATOM_ENCODER_CAP_RECORD_HBR3_EN))) result=R4DCN_UNSUPPORTED;
 else {
  l->settings=(struct dc_link_settings){.lane_count=lanes,.link_rate=rate,.link_spread=spread?LINK_SPREAD_05_DOWNSPREAD_30KHZ:LINK_SPREAD_DISABLED};
  l->enabled=1; /* Retain before any partial transmitter command/fatal exit. */
  dcn10_link_encoder_setup(&l->encoder.base,SIGNAL_TYPE_EDP);
  dcn10_link_encoder_enable_dp_output(&l->encoder.base,&l->settings,CLOCK_SOURCE_ID_EXTERNAL);
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_link_train(void *storage,uint32_t index,uint32_t pattern,const uint8_t lane_settings[4]) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!l || !l->enabled || !lane_settings || pattern>4 || d->fault) result=R4DCN_STATE;
 else {
  struct dc_lane_settings lanes[4]={0};
  for(unsigned i=0;i<(unsigned)l->settings.lane_count;i++) {
   unsigned swing=lane_settings[i]&3,pre=(lane_settings[i]>>3)&3;
   if(swing+pre>3 || (lane_settings[i]&0xc0)) result=R4DCN_INVALID;
   lanes[i].VOLTAGE_SWING=swing;lanes[i].PRE_EMPHASIS=pre;
  }
  if(!result) {
   dcn10_link_encoder_dp_set_lane_settings(&l->encoder.base,&l->settings,lanes);
   static const enum dp_test_pattern patterns[]={DP_TEST_PATTERN_VIDEO_MODE,DP_TEST_PATTERN_TRAINING_PATTERN1,DP_TEST_PATTERN_TRAINING_PATTERN2,DP_TEST_PATTERN_TRAINING_PATTERN3,DP_TEST_PATTERN_TRAINING_PATTERN4};
   struct encoder_set_dp_phy_pattern_param p={.dp_phy_pattern=patterns[pattern],.dp_panel_mode=DP_PANEL_MODE_DEFAULT};
   if(!d->fault)dcn10_link_encoder_dp_set_phy_pattern(&l->encoder.base,&p);
  }
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_link_hpd(void *storage,uint32_t index,uint32_t *present) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!l || !present || d->fault)result=R4DCN_STATE;
 else {*present=((rd(d,ADDR(DC_GPIO_HPD_Y))>>l->route.hpd_shift)&1)==l->route.hpd_active;if(d->fault)result=d->fault;}
 r4dcn_leave(d);return result;
}
int r4dcn_link_video(void *storage,uint32_t index,uint32_t pipe,uint32_t *active) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 static const uint32_t video_regs[]={ADDR(DP0_DP_VID_STREAM_CNTL),ADDR(DP1_DP_VID_STREAM_CNTL),ADDR(DP2_DP_VID_STREAM_CNTL),ADDR(DP3_DP_VID_STREAM_CNTL)};
 if(!l || !active || pipe>=4 || d->fault)result=R4DCN_STATE;
 else {
  uint32_t tg=rd(d,tg_regs[pipe].OTG_CONTROL),video=rd(d,video_regs[l->route.phy]);
  *active=!!(tg&OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK) &&
   !!(video&DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_ENABLE_MASK) && !!(video&DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK);
  if(l->dp_stream_bound)*active&=l->stream.base.funcs->dig_source_otg(&l->stream.base)==pipe;
  if(d->fault)result=d->fault;
 }
 r4dcn_leave(d);return result;
}
int r4dcn_link_restore_pads(void *storage,uint32_t index) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link_at(d,index);
 if(!l || l->enabled || l->ddc_open || d->fault)result=R4DCN_STATE;
 else if(l->pads_held) {
  uint32_t bit=1u<<l->route.hpd_shift,value=rd(d,ADDR(DC_GPIO_HPD_MASK));
  wr(d,ddc_mask[l->route.aux],l->pad_mask);wr(d,ADDR(DC_GPIO_HPD_MASK),(value&~bit)|(l->hpd_mask&bit));
  if(d->fault)result=d->fault;else {l->pads_held=0;l->initialized=0;}
 }
 r4dcn_leave(d);return result;
}
static void panel_state(struct r4dcn *d,struct r4dcn_panel_state *s) {
 struct panel_cntl *p=&d->panel.base;
 memset(s,0,sizeof(*s));
 s->powered=p->funcs->is_panel_powered_on(p);s->lit=p->funcs->is_panel_backlight_on(p);
 uint32_t period=rd(d,panel_cntl_regs[0].BL_PWM_PERIOD_CNTL),ctl=rd(d,panel_cntl_regs[0].BL_PWM_CNTL);
 unsigned bits=(period&BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT_MASK)>>BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT__SHIFT;if(!bits)bits=16;
 s->firmware_busy=!(rd(d,ADDR(DMCU_STATUS))&DMCU_STATUS__UC_IN_RESET_MASK) ||
  ((rd(d,ADDR(ABM0_BL1_PWM_ABM_CNTL))|rd(d,ADDR(ABM1_BL1_PWM_ABM_CNTL)))&
   (ABM0_BL1_PWM_ABM_CNTL__BL1_PWM_USE_ABM_EN_MASK|ABM0_BL1_PWM_ABM_CNTL__BL1_PWM_USE_AMBIENT_LEVEL_EN_MASK|
    ABM0_BL1_PWM_ABM_CNTL__BL1_PWM_AUTO_UPDATE_CURRENT_ABM_LEVEL_EN_MASK|ABM0_BL1_PWM_ABM_CNTL__BL1_PWM_AUTO_CALC_FINAL_DUTY_CYCLE_EN_MASK));
 if(bits<=16) {s->period=period&((1u<<bits)-1);s->pwm_valid=s->period && (ctl&BL_PWM_CNTL__BL_PWM_EN_MASK);}
 if(s->pwm_valid)s->pwm=p->funcs->get_current_backlight(p);
 if(s->pwm>65536)s->pwm_valid=0;
}
int r4dcn_panel_read(void *storage,struct r4dcn_panel_state *out) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(!out || !d->panel_constructed || d->fault)result=R4DCN_STATE;
 else {panel_state(d,out);if(d->fault)result=d->fault;}
 r4dcn_leave(d);return result;
}
int r4dcn_panel_pwm(void *storage,uint32_t pwm) {
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 if(pwm>65536 || !d->panel_constructed || d->fault)result=R4DCN_INVALID;
 else {
  struct r4dcn_panel_state state;panel_state(d,&state);
  if(d->fault)result=d->fault;
  else if(!state.pwm_valid || state.firmware_busy)result=R4DCN_UNSUPPORTED;
  else {
   uint32_t scratch=rd(d,panel_cntl_regs[0].BIOS_SCRATCH_2);
   wr(d,panel_cntl_regs[0].BIOS_SCRATCH_2,scratch|ATOM_S2_VRI_BRIGHT_ENABLE);
   d->panel.base.funcs->driver_set_backlight(&d->panel.base,pwm);
   if(!d->fault) {
    uint32_t period=rd(d,panel_cntl_regs[0].BL_PWM_PERIOD_CNTL);
    uint32_t bits=(period&BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT_MASK)>>BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT__SHIFT;
    if(!bits)bits=16;
    if(bits>16)result=R4DCN_IO;
    else {
     uint64_t duty=(uint64_t)pwm*state.period;
     uint32_t expected=((duty>>bits)&65535)+((duty>>(bits-1))&1);
     uint32_t actual=rd(d,panel_cntl_regs[0].BL_PWM_CNTL)&BL_PWM_CNTL__BL_ACTIVE_INT_FRAC_CNT_MASK;
     if(actual!=(expected&65535))result=R4DCN_IO;
    }
   }
   if(d->fault)result=d->fault;
  }
 }
 r4dcn_leave(d);return result;
}
