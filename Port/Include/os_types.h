/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4OS_DCN_OS_TYPES_H
#define R4OS_DCN_OS_TYPES_H
/* Scope: the genuine DCN1 dcn_calc_math.c dependency only. This is not a
 * substitute Linux/DC type system. The display port must provide this fatal
 * assertion and run floating-point calculations in a SIMD-enabled worker. */
_Noreturn void r4amd_dcn_assert(const char *expression, const char *file, unsigned line);
#define ASSERT(condition) ((condition) ? (void)0 : r4amd_dcn_assert(#condition, __FILE__, __LINE__))
#endif
