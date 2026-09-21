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
/* Embedded GPIO adaptation follows AMD hw_gpio/hw_ddc; parameter layouts
 * follow command_table2. AMD notices accompany this adaptation. */
#include "dcn_internal.h"
#include "dcn_hdmi_tables.h"
#include "gpio_service_interface.h"
#include "atomfirmware.h"
#define ADDR(reg) (BASE(mm##reg##_BASE_IDX)+mm##reg)
static const uint32_t pads[]={ADDR(DC_GPIO_DDC1_MASK),ADDR(DC_GPIO_DDC2_MASK),ADDR(DC_GPIO_DDC3_MASK),ADDR(DC_GPIO_DDC4_MASK)};
static const struct resource_caps caps={.num_ddc=4};
static uint32_t rd(struct r4dcn *d,uint32_t reg){return dm_read_reg_func(&d->ctx,reg,__func__);}
static void wr(struct r4dcn *d,uint32_t reg,uint32_t v){dm_write_reg_func(&d->ctx,reg,v,__func__);}
static struct r4dcn_link *link(struct r4dcn *d,unsigned i){return i<4 && d->links[i].bound && (d->links[i].route.connector&255)==0x0c?&d->links[i]:NULL;}
static struct r4dcn_link *pin(const struct ddc *ddc){
 if(!ddc || !r4dcn_current || ddc->ctx!=&r4dcn_current->ctx)return NULL;
 for(unsigned i=0;i<4;i++) if(ddc==&r4dcn_current->links[i].gpio_ddc)return link(r4dcn_current,i);
 return NULL;
}
enum gpio_ddc_line dal_ddc_get_line(const struct ddc *ddc){
 struct r4dcn_link *l=pin(ddc);ASSERT(l);return l?l->route.aux:GPIO_DDC_LINE_UNKNOWN;
}
enum gpio_result dal_ddc_open(struct ddc *ddc,enum gpio_mode mode,enum gpio_ddc_config_type type){
 struct r4dcn_link *l=pin(ddc);struct r4dcn *d=r4dcn_current;
 if(!l || !l->i2c_ready || l->ddc_open || d->fault || mode!=GPIO_MODE_HARDWARE || type!=GPIO_DDC_CONFIG_TYPE_MODE_I2C)return GPIO_RESULT_NON_SPECIFIC_ERROR;
 uint32_t reg=pads[l->route.aux],value=rd(d,reg);
 if(d->fault)return GPIO_RESULT_NON_SPECIFIC_ERROR;
 l->ddc_saved_mask=value;l->ddc_open=1; /* Retain before the first write. */
 value&=~(DC_GPIO_DDC1_MASK__DC_GPIO_DDC1CLK_MASK_MASK|DC_GPIO_DDC1_MASK__DC_GPIO_DDC1DATA_MASK_MASK);
 value|=DC_GPIO_DDC1_MASK__DC_GPIO_DDC1CLK_PD_EN_MASK|DC_GPIO_DDC1_MASK__DC_GPIO_DDC1DATA_PD_EN_MASK;
 wr(d,reg,value);
 if(value&DC_GPIO_DDC1_MASK__AUX_PAD1_MODE_MASK) {
  udelay(2000);wr(d,reg,value&~DC_GPIO_DDC1_MASK__AUX_PAD1_MODE_MASK);
 }
 return d->fault?GPIO_RESULT_NON_SPECIFIC_ERROR:GPIO_RESULT_OK;
}
void dal_ddc_close(struct ddc *ddc){
 if(!ddc)return; /* Raw AUX deliberately has no GPIO object. */
 struct r4dcn_link *l=pin(ddc);ASSERT(l);
 if(l && l->ddc_open) {
  wr(r4dcn_current,pads[l->route.aux],l->ddc_saved_mask);
  if(!r4dcn_current->fault)l->ddc_open=0;
 }
}
enum bp_result r4dcn_hdmi_encoder(struct dc_bios *bios,struct bp_encoder_control *ctl){
 struct r4dcn *d=bios->ctx->driver_context;struct r4dcn_link *l=NULL;
 for(unsigned i=0;i<4;i++) if(link(d,i) && d->links[i].stream.base.id==ctl->engine_id) l=&d->links[i];
 if(!l || !l->i2c_ready || d->fault || ctl->action!=ENCODER_CONTROL_SETUP || ctl->signal!=SIGNAL_TYPE_HDMI_TYPE_A ||
  ctl->enable_dp_audio || ctl->pixel_clock<10000 || ctl->pixel_clock>340000)return BP_RESULT_UNSUPPORTED;
 struct dig_encoder_stream_setup_parameters_v1_5 p={.digid=ctl->engine_id-ENGINE_ID_DIGA,
  .action=ATOM_ENCODER_CMD_STREAM_SETUP,.digmode=ATOM_ENCODER_MODE_HDMI,.lanenum=4,
  .pclk_10khz=ctl->pixel_clock/10,.bitpercolor=PANEL_8BIT_PER_COLOR};
 uint32_t words[sizeof(p)/4];memcpy(words,&p,sizeof(p));
 unsigned cmd=offsetof(struct atom_master_list_of_command_functions_v2_1,digxencodercontrol)/2;
 if(l->atom.execute(l->atom.context,cmd,words,ARRAY_SIZE(words))) {d->fault=R4DCN_IO;return BP_RESULT_FAILURE;}
 return BP_RESULT_OK;
}
int r4dcn_hdmi_bind(void *storage,uint32_t index,uint32_t crystal_khz){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link(d,index);
 if(!l || l->i2c_ready || crystal_khz<24000 || crystal_khz>100000 || crystal_khz%10 || d->fault)result=R4DCN_INVALID;
 else {
  d->bios.fw_info.pll_info.crystal_frequency=crystal_khz;
  d->pool.res_cap=&caps;d->dc.caps.i2c_speed_in_khz=d->dc.caps.i2c_speed_in_khz_hdcp=100;
  l->gpio_ddc.ctx=&d->ctx;l->gpio_ddc.hw_info.hw_supported=true;l->gpio_ddc.hw_info.ddc_channel=l->route.aux;
  dcn1_i2c_hw_construct(&l->i2c,&d->ctx,l->route.aux,&i2c_hw_regs[l->route.aux],&i2c_shifts,&i2c_masks);
  d->pool.hw_i2cs[l->route.aux]=&l->i2c;
  dcn10_stream_encoder_construct(&l->stream,&d->ctx,&d->bios,ENGINE_ID_DIGA+l->route.phy,&stream_enc_regs[l->route.phy],&se_shift,&se_mask);
  l->i2c_ready=1;
 }
 r4dcn_leave(d);return result;
}
int r4dcn_hdmi_edid(void *storage,uint32_t index,uint32_t block,uint8_t data[128]){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link(d,index);
 if(!l || !l->i2c_ready || !l->initialized || !data || block>=32 || d->fault)result=R4DCN_STATE;
 else {
  uint8_t segment=block/2,offset=(block&1)*128,bytes[128];
  struct i2c_payload payloads[]={ {.write=true,.address=0x30,.length=1,.data=&segment},
   {.write=true,.address=0x50,.length=1,.data=&offset},{.write=false,.address=0x50,.length=128,.data=bytes} };
  /* Segment zero is implicit on ordinary two-block sinks, which may NACK
   * address 0x30. Nonzero segments require the combined E-DDC transaction. */
  struct i2c_command command={.payloads=&payloads[segment?0:1],.number_of_payloads=segment?3:2,.speed=100};
  struct dce_i2c_hw *engine=acquire_i2c_hw_engine(&d->pool,&l->gpio_ddc);
  if(!engine) {
   /* Upstream acquisition failure releases arbitration but leaves the pin
    * open. Our embedded owner must close it on this path as well. */
   if(l->ddc_open)dal_ddc_close(&l->gpio_ddc);
   l->i2c.ddc=NULL;result=R4DCN_IO;
  } else if(!dce_i2c_submit_command_hw(&d->pool,&l->gpio_ddc,&command,engine))result=R4DCN_IO;
  if(d->fault)result=d->fault;
  if(!result)memcpy(data,bytes,sizeof(bytes));
 }
 r4dcn_leave(d);return result;
}
int r4dcn_hdmi_configure(void *storage,uint32_t index,uint32_t pipe,const uint8_t avi[17]){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;
 struct r4dcn_link *l=link(d,index);unsigned sum=0;
 if(avi)for(unsigned i=0;i<17;i++)sum+=avi[i];
 if(!l || !l->i2c_ready || !l->initialized || !avi || pipe>=4 || !(d->mask&(1u<<pipe)) || !d->prepared || d->fault)result=R4DCN_STATE;
 else if(avi[0]!=0x82 || avi[1]!=2 || avi[2]!=13 || sum%256 || avi[4]&0xe0 ||
  d->streams[pipe].signal!=SIGNAL_TYPE_HDMI_TYPE_A || d->streams[pipe].timing.pix_clk_100hz>3400000)result=R4DCN_INVALID;
 else if(l->enabled || dcn10_is_dig_enabled(&l->encoder.base) ||
   rd(d,tg_regs[pipe].OTG_CONTROL)&(OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK|OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK))result=R4DCN_STATE;
 else {
  struct stream_encoder *enc=&l->stream.base;
  l->hdmi_configured=0;l->hdmi_pipe=pipe;
  dcn10_link_encoder_setup(&l->encoder.base,SIGNAL_TYPE_HDMI_TYPE_A);
  enc->funcs->dig_connect_to_otg(enc,pipe);
  enc->funcs->hdmi_set_stream_attribute(enc,&d->streams[pipe].timing,d->streams[pipe].timing.pix_clk_100hz/10,false);
  if(!d->fault) {
   enc->funcs->set_avmute(enc,true);
   /* HDMI1.4 has no SCDC/scrambler, including the exact 340MHz boundary. */
   uint32_t ctl=rd(d,l->stream.regs->HDMI_CONTROL);
   wr(d,l->stream.regs->HDMI_CONTROL,ctl&~(DIG0_HDMI_CONTROL__HDMI_DATA_SCRAMBLE_EN_MASK|DIG0_HDMI_CONTROL__HDMI_CLOCK_CHANNEL_RATE_MASK));
   enc->funcs->audio_mute_control(enc,true);enc->funcs->hdmi_audio_disable(enc);
   uint32_t info=rd(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0);
   wr(d,l->stream.regs->HDMI_INFOFRAME_CONTROL0,info&~DIG0_HDMI_INFOFRAME_CONTROL0__HDMI_AUDIO_INFO_SEND_MASK);
   struct encoder_info_frame frames={0};frames.avi.valid=true;
   frames.avi.hb0=avi[0];frames.avi.hb1=avi[1];frames.avi.hb2=avi[2];
   memcpy(frames.avi.sb,&avi[3],14);
   enc->funcs->update_hdmi_info_packets(enc,&frames);
   if(!d->fault)l->hdmi_configured=1;
  }
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_hdmi_enable(void *storage,uint32_t index){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;struct r4dcn_link *l=link(d,index);
 if(!l || !l->hdmi_configured || !d->programmed || l->enabled || d->fault)result=R4DCN_STATE;
 else {
  l->enabled=1;
  dcn10_link_encoder_enable_tmds_output(&l->encoder.base,CLOCK_SOURCE_COMBO_PHY_PLL0+l->route.phy,COLOR_DEPTH_888,SIGNAL_TYPE_HDMI_TYPE_A,d->streams[l->hdmi_pipe].timing.pix_clk_100hz/10);
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_hdmi_mute(void *storage,uint32_t index,uint32_t mute){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;struct r4dcn_link *l=link(d,index);
 if(!l || !l->hdmi_configured || mute>1 || (!mute && !l->enabled) || d->fault)result=R4DCN_STATE;
 else if(!mute && (!dcn10_is_dig_enabled(&l->encoder.base) ||
  !(rd(d,tg_regs[l->hdmi_pipe].OTG_CONTROL)&OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK)))result=R4DCN_STATE;
 else l->stream.base.funcs->set_avmute(&l->stream.base,mute);
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
int r4dcn_hdmi_stopped(void *storage,uint32_t index,uint32_t *stopped){
 struct r4dcn *d=storage;int result=r4dcn_enter(d);if(result)return result;struct r4dcn_link *l=link(d,index);
 if(!l || !l->i2c_ready || !stopped || d->fault)result=R4DCN_STATE;
 else {
  *stopped=!l->enabled && !dcn10_is_dig_enabled(&l->encoder.base);
  if(l->hdmi_configured)*stopped&=!(rd(d,tg_regs[l->hdmi_pipe].OTG_CONTROL)&(OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK|OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK));
 }
 if(d->fault)result=d->fault;r4dcn_leave(d);return result;
}
