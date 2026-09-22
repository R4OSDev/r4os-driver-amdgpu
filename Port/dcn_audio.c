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
/* Embedded object/table adaptation; original AMD audio/stream algorithms. */
#include "dcn_internal.h"
#include "dcn_register_tables.h"
#define audio_regs(id) [id]={AUD_COMMON_REG_LIST(id)}
static const struct dce_audio_registers audio_regs[]={audio_regs(0),audio_regs(1),audio_regs(2),audio_regs(3)};
#define AUDIO_FIELDS(s) SF(AZF0ENDPOINT0_AZALIA_F0_CODEC_ENDPOINT_INDEX,AZALIA_ENDPOINT_REG_INDEX,s),SF(AZF0ENDPOINT0_AZALIA_F0_CODEC_ENDPOINT_DATA,AZALIA_ENDPOINT_REG_DATA,s),AUD_COMMON_MASK_SH_LIST_BASE(s)
static const struct dce_audio_shift audio_shift={AUDIO_FIELDS(__SHIFT)};
static const struct dce_audio_mask audio_mask={AUDIO_FIELDS(_MASK)};
static struct r4dcn_link *port(struct r4dcn *d,unsigned index){
 return index<4 && d->links[index].bound && d->links[index].i2c_ready && d->links[index].initialized && (d->links[index].route.connector&255)==0x0c?&d->links[index]:NULL;
}
static uint32_t rd(struct r4dcn *d,uint32_t r){return dm_read_reg(&d->ctx,r);}
static void wr(struct r4dcn *d,uint32_t r,uint32_t v){dm_write_reg(&d->ctx,r,v);}
static uint32_t az_read(struct r4dcn *d,unsigned inst,uint32_t r){wr(d,audio_regs[inst].AZALIA_F0_CODEC_ENDPOINT_INDEX,r);return rd(d,audio_regs[inst].AZALIA_F0_CODEC_ENDPOINT_DATA);}
/* Endpoint register indices are shared with the original DCE11 audio unit. */
#define PIN_DEFAULT 0x56
#define PIN_HOTPLUG 0x54
#define PIN_DESCRIPTOR0 0x28
int r4dcn_audio_bind(void *storage,uint32_t index,uint32_t *endpoint){
 struct r4dcn *d=storage;int rc=r4dcn_enter(d);if(rc)return rc;
 struct r4dcn_link *l=port(d,index);
 if(!l || !endpoint || d->fault)rc=R4DCN_STATE;
 else if(l->audio_bound)*endpoint=l->audio_inst;
 else {
  for(unsigned i=0;i<4;i++){
   d->audio[i]=(struct dce_audio){.base={.ctx=&d->ctx,.inst=i},.regs=&audio_regs[i],.shifts=&audio_shift,.masks=&audio_mask};
   uint32_t value=az_read(d,i,PIN_DEFAULT);
   if(d->fault)break;
   /* Actual endpoint connectivity, independent of display pipe or encoder. */
   if(((value>>30)&3)==1)continue;
   l->audio_inst=i;l->audio_bound=1;*endpoint=i;break;
  }
  if(!l->audio_bound)rc=R4DCN_UNSUPPORTED;
  else {
   /* The original init owns global rate fields only at instance zero. */
   if(l->audio_inst!=0)d->audio[0]=(struct dce_audio){.base={.ctx=&d->ctx,.inst=0},.regs=&audio_regs[0],.shifts=&audio_shift,.masks=&audio_mask};
   dce_aud_hw_init(&d->audio[0].base);dce_aud_az_disable(&d->audio[l->audio_inst].base);
  }
 }
 if(d->fault)rc=d->fault;r4dcn_leave(d);return rc;
}
static int stop(struct r4dcn *d,struct r4dcn_link *l){
 if(!l->audio_bound)return 0;
 struct stream_encoder *enc=&l->stream.base;
 enc->funcs->audio_mute_control(enc,true);
 enc->funcs->hdmi_audio_disable(enc);
 dce_aud_az_disable(&d->audio[l->audio_inst].base);
 uint32_t info=rd(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0);
 wr(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0,info&~DIG0_HDMI_INFOFRAME_CONTROL0__HDMI_AUDIO_INFO_SEND_MASK);
 if(d->fault)return d->fault;
 if((rd(d,l->stream.regs->AFMT_AUDIO_PACKET_CONTROL)&DIG0_AFMT_AUDIO_PACKET_CONTROL__AFMT_AUDIO_SAMPLE_SEND_MASK) || (az_read(d,l->audio_inst,PIN_HOTPLUG)&0x80000000u))return R4DCN_BUSY;
 l->audio_configured=l->audio_enabled=0;return 0;
}
int r4dcn_audio_stop(void *storage,uint32_t index){
 struct r4dcn *d=storage;int rc=r4dcn_enter(d);if(rc)return rc;struct r4dcn_link *l=port(d,index);
 rc=l?stop(d,l):R4DCN_STATE;if(d->fault)rc=d->fault;r4dcn_leave(d);return rc;
}
int r4dcn_audio_configure(void *storage,uint32_t index,const uint8_t *eld,uint32_t bytes){
 struct r4dcn *d=storage;int rc=r4dcn_enter(d);if(rc)return rc;struct r4dcn_link *l=port(d,index);
 unsigned name=eld && bytes>=20?(eld[4]&31):0;
 if(!l || !l->audio_bound || !l->hdmi_configured || l->audio_enabled || d->fault)rc=R4DCN_STATE;
 else if(!eld || bytes<24 || bytes>40 || bytes%4 || eld[0]!=16 || 4+eld[2]*4!=bytes || name>16 || 23+name>bytes ||
  eld[5]>>4!=1 || eld[5]&0x0c || eld[7]!=1 || eld[20+name]!=9 || eld[21+name]!=4 || eld[22+name]!=1)rc=R4DCN_INVALID;
 else {
  struct dc_stream_state *s=&d->streams[l->hdmi_pipe];
  struct audio_info info={.manufacture_id=eld[16]|eld[17]<<8,.product_id=eld[18]|eld[19]<<8,.mode_count=1};
  info.flags.info.ALLSPEAKERS=1;info.flags.info.SUPPORT_AI=(eld[5]>>1)&1;
  memcpy(info.port_id,&eld[8],8);memcpy(info.display_name,&eld[20],name);
  /* ELD stores relative latency; reconstruct equivalent HDMI VSDB units. */
  info.video_latency=eld[6]?eld[6]+1:0;info.audio_latency=eld[6]?1:0;
  info.modes[0]=(struct audio_mode){.format_code=AUDIO_FORMAT_CODE_LINEARPCM,.channel_count=2,.sample_rates={.all=4},.sample_size=1};
  uint32_t clock=s->timing.pix_clk_100hz;
  if(s->timing.display_color_depth==COLOR_DEPTH_101010)clock=(uint32_t)(((uint64_t)clock*5+3)/4);
  struct audio_crtc_info crtc={.h_total=s->timing.h_total,.h_active=s->timing.h_addressable,.v_active=s->timing.v_addressable,
   .requested_pixel_clock_100Hz=clock,.calculated_pixel_clock_100Hz=clock,.color_depth=s->timing.display_color_depth,
   .pixel_encoding=PIXEL_ENCODING_RGB,.pixel_repetition=1,.refresh_rate=(uint16_t)(((uint64_t)s->timing.pix_clk_100hz*100)/(s->timing.h_total*s->timing.v_total))};
  struct audio_pll_info pll={.dto_source=DTO_SOURCE_ID0+l->hdmi_pipe};
  struct audio *audio=&d->audio[l->audio_inst].base;struct stream_encoder *enc=&l->stream.base;
  dce_aud_az_disable(audio);enc->funcs->audio_mute_control(enc,true);
  enc->funcs->hdmi_audio_setup(enc,l->audio_inst,&info,&crtc);
  dce_aud_az_configure(audio,SIGNAL_TYPE_HDMI_TYPE_A,&crtc,&info,NULL);
  dce_aud_az_disable_hbr_audio(audio);dce_aud_wall_dto_setup(audio,SIGNAL_TYPE_HDMI_TYPE_A,&crtc,&pll);
  /* Original bandwidth adjustment must preserve the admitted wire format. */
  if(!d->fault && az_read(d,l->audio_inst,PIN_DESCRIPTOR0)==0x04010401)l->audio_configured=1;
  else rc=R4DCN_UNSUPPORTED;
 }
 if(d->fault)rc=d->fault;r4dcn_leave(d);return rc;
}
int r4dcn_audio_enable(void *storage,uint32_t index){
 struct r4dcn *d=storage;int rc=r4dcn_enter(d);if(rc)return rc;struct r4dcn_link *l=port(d,index);
 if(!l || !l->audio_configured || !l->enabled || d->fault)rc=R4DCN_STATE;
 else if(!dcn10_is_dig_enabled(&l->encoder.base) || !(rd(d,tg_regs[l->hdmi_pipe].OTG_CONTROL)&OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK))rc=R4DCN_STATE;
 else {
  dce_aud_az_enable(&d->audio[l->audio_inst].base);
  wr(d,l->stream.regs->AFMT_INFOFRAME_CONTROL0,rd(d,l->stream.regs->AFMT_INFOFRAME_CONTROL0)|DIG0_AFMT_INFOFRAME_CONTROL0__AFMT_AUDIO_INFO_UPDATE_MASK);
  wr(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0,rd(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0)|DIG0_HDMI_INFOFRAME_CONTROL0__HDMI_AUDIO_INFO_SEND_MASK);
  l->stream.base.funcs->audio_mute_control(&l->stream.base,false);
  if(!d->fault && (az_read(d,l->audio_inst,PIN_HOTPLUG)&0x80000000u) && (rd(d,l->stream.regs->AFMT_AUDIO_PACKET_CONTROL)&DIG0_AFMT_AUDIO_PACKET_CONTROL__AFMT_AUDIO_SAMPLE_SEND_MASK))l->audio_enabled=1;
  else rc=R4DCN_BUSY;
 }
 if(d->fault)rc=d->fault;r4dcn_leave(d);return rc;
}
