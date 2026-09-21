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
/* R4OS DCN1 connector register selection. */
#include "dcn_register_tables.h"
#include "nbio/nbio_7_0_offset.h"
#include "dce/dce_aux.h"
#include "dce/dce_panel_cntl.h"
#include "dio/dcn10/dcn10_link_encoder.h"
#ifndef mmDP0_DP_DPHY_INTERNAL_CTRL
#define mmDP0_DP_DPHY_INTERNAL_CTRL 0x210f
#define mmDP0_DP_DPHY_INTERNAL_CTRL_BASE_IDX 2
#define mmDP1_DP_DPHY_INTERNAL_CTRL 0x220f
#define mmDP1_DP_DPHY_INTERNAL_CTRL_BASE_IDX 2
#define mmDP2_DP_DPHY_INTERNAL_CTRL 0x230f
#define mmDP2_DP_DPHY_INTERNAL_CTRL_BASE_IDX 2
#define mmDP3_DP_DPHY_INTERNAL_CTRL 0x240f
#define mmDP3_DP_DPHY_INTERNAL_CTRL_BASE_IDX 2
#endif
#define aux_regs(id)\
[id] = {\
	AUX_REG_LIST(id)\
}

static const struct dcn10_link_enc_aux_registers link_enc_aux_regs[] = {
		aux_regs(0),
		aux_regs(1),
		aux_regs(2),
		aux_regs(3)
};

#define hpd_regs(id)\
[id] = {\
	HPD_REG_LIST(id)\
}

static const struct dcn10_link_enc_hpd_registers link_enc_hpd_regs[] = {
		hpd_regs(0),
		hpd_regs(1),
		hpd_regs(2),
		hpd_regs(3)
};

#define link_regs(id)\
[id] = {\
	LE_DCN10_REG_LIST(id), \
	SRI(DP_DPHY_INTERNAL_CTRL, DP, id) \
}

static const struct dcn10_link_enc_registers link_enc_regs[] = {
	link_regs(0),
	link_regs(1),
	link_regs(2),
	link_regs(3)
};

static const struct dcn10_link_enc_shift le_shift = {
		LINK_ENCODER_MASK_SH_LIST_DCN10(__SHIFT)
};

static const struct dcn10_link_enc_mask le_mask = {
		LINK_ENCODER_MASK_SH_LIST_DCN10(_MASK)
};

static const struct dce_panel_cntl_registers panel_cntl_regs[] = {
	{ DCN_PANEL_CNTL_REG_LIST() }
};

static const struct dce_panel_cntl_shift panel_cntl_shift = {
	DCE_PANEL_CNTL_MASK_SH_LIST(__SHIFT)
};

static const struct dce_panel_cntl_mask panel_cntl_mask = {
	DCE_PANEL_CNTL_MASK_SH_LIST(_MASK)
};

static const struct dce110_aux_registers_shift aux_shift = {
	DCN10_AUX_MASK_SH_LIST(__SHIFT)
};

static const struct dce110_aux_registers_mask aux_mask = {
	DCN10_AUX_MASK_SH_LIST(_MASK)
};

#define aux_engine_regs(id)\
[id] = {\
	AUX_COMMON_REG_LIST(id), \
	.AUX_RESET_MASK = 0 \
}

static const struct dce110_aux_registers aux_engine_regs[] = {
		aux_engine_regs(0),
		aux_engine_regs(1),
		aux_engine_regs(2),
		aux_engine_regs(3),
};
