// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// /*
//  * Copyright 2016 Advanced Micro Devices, Inc.
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  *
//  */
// 
//! VCN1 clock controls from AMD vcn_v1_0.c; gate only after exact retirement.
const r = @import("vcn_registers.zig");
const c = @import("start_common.zig");
pub fn enable(io: anytype) c.Error!void {
    var data: u32 = 0;
    data = try c.read(io, r.JPEG_CGC_CTRL);
    data &= ~r.JPEG_CGC_CTRL__DYN_CLOCK_MODE_MASK;
    data |= @as(u32, 1) << r.JPEG_CGC_CTRL__CLK_GATE_DLY_TIMER__SHIFT;
    data |= @as(u32, 4) << r.JPEG_CGC_CTRL__CLK_OFF_DELAY__SHIFT;
    try io.write(r.JPEG_CGC_CTRL, data);
    data = try c.read(io, r.JPEG_CGC_GATE);
    data &= ~(r.JPEG_CGC_GATE__JPEG_MASK | r.JPEG_CGC_GATE__JPEG2_MASK);
    try io.write(r.JPEG_CGC_GATE, data);
    data = try c.read(io, r.UVD_CGC_CTRL);
    data &= ~r.UVD_CGC_CTRL__DYN_CLOCK_MODE_MASK;
    data |= @as(u32, 1) << r.UVD_CGC_CTRL__CLK_GATE_DLY_TIMER__SHIFT;
    data |= @as(u32, 4) << r.UVD_CGC_CTRL__CLK_OFF_DELAY__SHIFT;
    try io.write(r.UVD_CGC_CTRL, data);
    data = try c.read(io, r.UVD_CGC_GATE);
    data &= ~(r.UVD_CGC_GATE__SYS_MASK | r.UVD_CGC_GATE__UDEC_MASK | r.UVD_CGC_GATE__MPEG2_MASK | r.UVD_CGC_GATE__REGS_MASK | r.UVD_CGC_GATE__RBC_MASK | r.UVD_CGC_GATE__LMI_MC_MASK | r.UVD_CGC_GATE__LMI_UMC_MASK | r.UVD_CGC_GATE__IDCT_MASK | r.UVD_CGC_GATE__MPRD_MASK | r.UVD_CGC_GATE__MPC_MASK | r.UVD_CGC_GATE__LBSI_MASK | r.UVD_CGC_GATE__LRBBM_MASK | r.UVD_CGC_GATE__UDEC_RE_MASK | r.UVD_CGC_GATE__UDEC_CM_MASK | r.UVD_CGC_GATE__UDEC_IT_MASK | r.UVD_CGC_GATE__UDEC_DB_MASK | r.UVD_CGC_GATE__UDEC_MP_MASK | r.UVD_CGC_GATE__WCB_MASK | r.UVD_CGC_GATE__VCPU_MASK | r.UVD_CGC_GATE__SCPU_MASK);
    try io.write(r.UVD_CGC_GATE, data);
    data = try c.read(io, r.UVD_CGC_CTRL);
    data &= ~(r.UVD_CGC_CTRL__UDEC_RE_MODE_MASK | r.UVD_CGC_CTRL__UDEC_CM_MODE_MASK | r.UVD_CGC_CTRL__UDEC_IT_MODE_MASK | r.UVD_CGC_CTRL__UDEC_DB_MODE_MASK | r.UVD_CGC_CTRL__UDEC_MP_MODE_MASK | r.UVD_CGC_CTRL__SYS_MODE_MASK | r.UVD_CGC_CTRL__UDEC_MODE_MASK | r.UVD_CGC_CTRL__MPEG2_MODE_MASK | r.UVD_CGC_CTRL__REGS_MODE_MASK | r.UVD_CGC_CTRL__RBC_MODE_MASK | r.UVD_CGC_CTRL__LMI_MC_MODE_MASK | r.UVD_CGC_CTRL__LMI_UMC_MODE_MASK | r.UVD_CGC_CTRL__IDCT_MODE_MASK | r.UVD_CGC_CTRL__MPRD_MODE_MASK | r.UVD_CGC_CTRL__MPC_MODE_MASK | r.UVD_CGC_CTRL__LBSI_MODE_MASK | r.UVD_CGC_CTRL__LRBBM_MODE_MASK | r.UVD_CGC_CTRL__WCB_MODE_MASK | r.UVD_CGC_CTRL__VCPU_MODE_MASK | r.UVD_CGC_CTRL__SCPU_MODE_MASK);
    try io.write(r.UVD_CGC_CTRL, data);
    data = try c.read(io, r.UVD_SUVD_CGC_GATE);
    data |= (r.UVD_SUVD_CGC_GATE__SRE_MASK | r.UVD_SUVD_CGC_GATE__SIT_MASK | r.UVD_SUVD_CGC_GATE__SMP_MASK | r.UVD_SUVD_CGC_GATE__SCM_MASK | r.UVD_SUVD_CGC_GATE__SDB_MASK | r.UVD_SUVD_CGC_GATE__SRE_H264_MASK | r.UVD_SUVD_CGC_GATE__SRE_HEVC_MASK | r.UVD_SUVD_CGC_GATE__SIT_H264_MASK | r.UVD_SUVD_CGC_GATE__SIT_HEVC_MASK | r.UVD_SUVD_CGC_GATE__SCM_H264_MASK | r.UVD_SUVD_CGC_GATE__SCM_HEVC_MASK | r.UVD_SUVD_CGC_GATE__SDB_H264_MASK | r.UVD_SUVD_CGC_GATE__SDB_HEVC_MASK | r.UVD_SUVD_CGC_GATE__SCLR_MASK | r.UVD_SUVD_CGC_GATE__UVD_SC_MASK | r.UVD_SUVD_CGC_GATE__ENT_MASK | r.UVD_SUVD_CGC_GATE__SIT_HEVC_DEC_MASK | r.UVD_SUVD_CGC_GATE__SIT_HEVC_ENC_MASK | r.UVD_SUVD_CGC_GATE__SITE_MASK | r.UVD_SUVD_CGC_GATE__SRE_VP9_MASK | r.UVD_SUVD_CGC_GATE__SCM_VP9_MASK | r.UVD_SUVD_CGC_GATE__SIT_VP9_DEC_MASK | r.UVD_SUVD_CGC_GATE__SDB_VP9_MASK | r.UVD_SUVD_CGC_GATE__IME_HEVC_MASK);
    try io.write(r.UVD_SUVD_CGC_GATE, data);
    data = try c.read(io, r.UVD_SUVD_CGC_CTRL);
    data &= ~(r.UVD_SUVD_CGC_CTRL__SRE_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SIT_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SMP_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SCM_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SDB_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SCLR_MODE_MASK | r.UVD_SUVD_CGC_CTRL__UVD_SC_MODE_MASK | r.UVD_SUVD_CGC_CTRL__ENT_MODE_MASK | r.UVD_SUVD_CGC_CTRL__IME_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SITE_MODE_MASK);
    try io.write(r.UVD_SUVD_CGC_CTRL, data);
}

/// Caller has observed idle rings and retired every VCN timeline resource.
pub fn gate(io: anytype) c.Error!void {
    var data = try c.read(io, r.JPEG_CGC_CTRL);
    data |= r.JPEG_CGC_CTRL__DYN_CLOCK_MODE_MASK | (1 << r.JPEG_CGC_CTRL__CLK_GATE_DLY_TIMER__SHIFT) | (4 << r.JPEG_CGC_CTRL__CLK_OFF_DELAY__SHIFT);
    try io.write(r.JPEG_CGC_CTRL, data);
    try c.set(io, r.JPEG_CGC_GATE, r.JPEG_CGC_GATE__JPEG_MASK | r.JPEG_CGC_GATE__JPEG2_MASK, r.JPEG_CGC_GATE__JPEG_MASK | r.JPEG_CGC_GATE__JPEG2_MASK);
    data = try c.read(io, r.UVD_CGC_CTRL);
    data |= r.UVD_CGC_CTRL__DYN_CLOCK_MODE_MASK | (1 << r.UVD_CGC_CTRL__CLK_GATE_DLY_TIMER__SHIFT) | (4 << r.UVD_CGC_CTRL__CLK_OFF_DELAY__SHIFT);
    try io.write(r.UVD_CGC_CTRL, data);
    data = try c.read(io, r.UVD_CGC_CTRL);
    data |= (r.UVD_CGC_CTRL__UDEC_RE_MODE_MASK | r.UVD_CGC_CTRL__UDEC_CM_MODE_MASK | r.UVD_CGC_CTRL__UDEC_IT_MODE_MASK | r.UVD_CGC_CTRL__UDEC_DB_MODE_MASK | r.UVD_CGC_CTRL__UDEC_MP_MODE_MASK | r.UVD_CGC_CTRL__SYS_MODE_MASK | r.UVD_CGC_CTRL__UDEC_MODE_MASK | r.UVD_CGC_CTRL__MPEG2_MODE_MASK | r.UVD_CGC_CTRL__REGS_MODE_MASK | r.UVD_CGC_CTRL__RBC_MODE_MASK | r.UVD_CGC_CTRL__LMI_MC_MODE_MASK | r.UVD_CGC_CTRL__LMI_UMC_MODE_MASK | r.UVD_CGC_CTRL__IDCT_MODE_MASK | r.UVD_CGC_CTRL__MPRD_MODE_MASK | r.UVD_CGC_CTRL__MPC_MODE_MASK | r.UVD_CGC_CTRL__LBSI_MODE_MASK | r.UVD_CGC_CTRL__LRBBM_MODE_MASK | r.UVD_CGC_CTRL__WCB_MODE_MASK | r.UVD_CGC_CTRL__VCPU_MODE_MASK | r.UVD_CGC_CTRL__SCPU_MODE_MASK);
    try io.write(r.UVD_CGC_CTRL, data);
    data = try c.read(io, r.UVD_SUVD_CGC_CTRL);
    data |= (r.UVD_SUVD_CGC_CTRL__SRE_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SIT_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SMP_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SCM_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SDB_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SCLR_MODE_MASK | r.UVD_SUVD_CGC_CTRL__UVD_SC_MODE_MASK | r.UVD_SUVD_CGC_CTRL__ENT_MODE_MASK | r.UVD_SUVD_CGC_CTRL__IME_MODE_MASK | r.UVD_SUVD_CGC_CTRL__SITE_MODE_MASK);
    try io.write(r.UVD_SUVD_CGC_CTRL, data);
}
