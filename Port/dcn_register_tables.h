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

/* R4OS selection of DCN1 frontend register tables. */
#include "core_types.h"
#include "reg_helper.h"
#include "hubp/dcn10/dcn10_hubp.h"
#include "hubbub/dcn10/dcn10_hubbub.h"
#include "dpp/dcn10/dcn10_dpp.h"
#include "optc/dcn10/dcn10_optc.h"
#include "opp/dcn10/dcn10_opp.h"
#include "mpc/dcn10/dcn10_mpc.h"
#include "dcn10/dcn10_ipp.h"
#include "vega10_ip_offset.h"
#include "asic_reg/dcn/dcn_1_0_offset.h"
#include "asic_reg/dcn/dcn_1_0_sh_mask.h"
#include "asic_reg/mmhub/mmhub_9_1_offset.h"
#include "asic_reg/mmhub/mmhub_9_1_sh_mask.h"
#define BASE_INNER(seg) \
	DCE_BASE__INST0_SEG ## seg

#define BASE(seg) \
	BASE_INNER(seg)
#define SF(reg_name,field_name,post_fix) .field_name = reg_name ## __ ## field_name ## post_fix

#define SR(reg_name)\
		.reg_name = BASE(mm ## reg_name ## _BASE_IDX) +  \
					mm ## reg_name

#define SRI(reg_name, block, id)\
	.reg_name = BASE(mm ## block ## id ## _ ## reg_name ## _BASE_IDX) + \
					mm ## block ## id ## _ ## reg_name


#define SRII(reg_name, block, id)\
	.reg_name[id] = BASE(mm ## block ## id ## _ ## reg_name ## _BASE_IDX) + \
					mm ## block ## id ## _ ## reg_name

#define VUPDATE_SRII(reg_name, block, id)\
	.reg_name[id] = BASE(mm ## reg_name ## 0 ## _ ## block ## id ## _BASE_IDX) + \
					mm ## reg_name ## 0 ## _ ## block ## id

/* set field/register/bitfield name */
#define SFRB(field_name, reg_name, bitfield, post_fix)\
	.field_name = reg_name ## __ ## bitfield ## post_fix

/* NBIO */
#define NBIO_BASE_INNER(seg) \
	NBIF_BASE__INST0_SEG ## seg

#define NBIO_BASE(seg) \
	NBIO_BASE_INNER(seg)

#define NBIO_SR(reg_name)\
		.reg_name = NBIO_BASE(mm ## reg_name ## _BASE_IDX) +  \
					mm ## reg_name

/* MMHUB */
#define MMHUB_BASE_INNER(seg) \
	MMHUB_BASE__INST0_SEG ## seg

#define MMHUB_BASE(seg) \
	MMHUB_BASE_INNER(seg)

#define MMHUB_SR(reg_name)\
		.reg_name = MMHUB_BASE(mm ## reg_name ## _BASE_IDX) +  \
					mm ## reg_name

#define ipp_regs(id)\
[id] = {\
	IPP_REG_LIST_DCN10(id),\
}

static const struct dcn10_ipp_registers ipp_regs[] = {
	ipp_regs(0),
	ipp_regs(1),
	ipp_regs(2),
	ipp_regs(3),
};

static const struct dcn10_ipp_shift ipp_shift = {
		IPP_MASK_SH_LIST_DCN10(__SHIFT)
};

static const struct dcn10_ipp_mask ipp_mask = {
		IPP_MASK_SH_LIST_DCN10(_MASK),
};

#define opp_regs(id)\
[id] = {\
	OPP_REG_LIST_DCN10(id),\
}

static const struct dcn10_opp_registers opp_regs[] = {
	opp_regs(0),
	opp_regs(1),
	opp_regs(2),
	opp_regs(3),
};

static const struct dcn10_opp_shift opp_shift = {
		OPP_MASK_SH_LIST_DCN10(__SHIFT)
};

static const struct dcn10_opp_mask opp_mask = {
		OPP_MASK_SH_LIST_DCN10(_MASK),
};


#define tf_regs(id)\
[id] = {\
	TF_REG_LIST_DCN10(id),\
}

static const struct dcn_dpp_registers tf_regs[] = {
	tf_regs(0),
	tf_regs(1),
	tf_regs(2),
	tf_regs(3),
};

static const struct dcn_dpp_shift tf_shift = {
	TF_REG_LIST_SH_MASK_DCN10(__SHIFT),
	TF_DEBUG_REG_LIST_SH_DCN10

};

static const struct dcn_dpp_mask tf_mask = {
	TF_REG_LIST_SH_MASK_DCN10(_MASK),
	TF_DEBUG_REG_LIST_MASK_DCN10
};

static const struct dcn_mpc_registers mpc_regs = {
		MPC_COMMON_REG_LIST_DCN1_0(0),
		MPC_COMMON_REG_LIST_DCN1_0(1),
		MPC_COMMON_REG_LIST_DCN1_0(2),
		MPC_COMMON_REG_LIST_DCN1_0(3),
		MPC_OUT_MUX_COMMON_REG_LIST_DCN1_0(0),
		MPC_OUT_MUX_COMMON_REG_LIST_DCN1_0(1),
		MPC_OUT_MUX_COMMON_REG_LIST_DCN1_0(2),
		MPC_OUT_MUX_COMMON_REG_LIST_DCN1_0(3)
};

static const struct dcn_mpc_shift mpc_shift = {
	MPC_COMMON_MASK_SH_LIST_DCN1_0(__SHIFT),\
	SFRB(CUR_VUPDATE_LOCK_SET, CUR0_VUPDATE_LOCK_SET0, CUR0_VUPDATE_LOCK_SET, __SHIFT)
};

static const struct dcn_mpc_mask mpc_mask = {
	MPC_COMMON_MASK_SH_LIST_DCN1_0(_MASK),\
	SFRB(CUR_VUPDATE_LOCK_SET, CUR0_VUPDATE_LOCK_SET0, CUR0_VUPDATE_LOCK_SET, _MASK)
};

#define tg_regs(id)\
[id] = {TG_COMMON_REG_LIST_DCN1_0(id)}

static const struct dcn_optc_registers tg_regs[] = {
	tg_regs(0),
	tg_regs(1),
	tg_regs(2),
	tg_regs(3),
};

static const struct dcn_optc_shift tg_shift = {
	TG_COMMON_MASK_SH_LIST_DCN1_0(__SHIFT)
};

static const struct dcn_optc_mask tg_mask = {
	TG_COMMON_MASK_SH_LIST_DCN1_0(_MASK)
};


#define hubp_regs(id)\
[id] = {\
	HUBP_REG_LIST_DCN10(id)\
}

static const struct dcn_mi_registers hubp_regs[] = {
	hubp_regs(0),
	hubp_regs(1),
	hubp_regs(2),
	hubp_regs(3),
};

static const struct dcn_mi_shift hubp_shift = {
		HUBP_MASK_SH_LIST_DCN10(__SHIFT)
};

static const struct dcn_mi_mask hubp_mask = {
		HUBP_MASK_SH_LIST_DCN10(_MASK)
};

static const struct dcn_hubbub_registers hubbub_reg = {
		HUBBUB_REG_LIST_DCN10(0)
};

static const struct dcn_hubbub_shift hubbub_shift = {
		HUBBUB_MASK_SH_LIST_DCN10(__SHIFT)
};

static const struct dcn_hubbub_mask hubbub_mask = {
		HUBBUB_MASK_SH_LIST_DCN10(_MASK)
};
