/*
 * Copyright 2017 Advanced Micro Devices, Inc.
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
 */
/* R4OS direct-MMIO register packing, derived from dc_helper.c. */
#include "dcn_internal.h"
struct dc_reg_value_masks {
	uint32_t value;
	uint32_t mask;
};

static inline void set_reg_field_value_masks(
	struct dc_reg_value_masks *field_value_mask,
	uint32_t value,
	uint32_t mask,
	uint8_t shift)
{
	ASSERT(mask != 0);

	field_value_mask->value = (field_value_mask->value & ~mask) | (mask & (value << shift));
	field_value_mask->mask = field_value_mask->mask | mask;
}

static void set_reg_field_values(struct dc_reg_value_masks *field_value_mask,
		uint32_t addr, int n,
		uint8_t shift1, uint32_t mask1, uint32_t field_value1,
		va_list ap)
{
	(void)addr;
	uint32_t shift, mask, field_value;
	int i = 1;

	/* gather all bits value/mask getting updated in this register */
	set_reg_field_value_masks(field_value_mask,
			field_value1, mask1, shift1);

	while (i < n) {
		shift = va_arg(ap, uint32_t);
		mask = va_arg(ap, uint32_t);
		field_value = va_arg(ap, uint32_t);

		set_reg_field_value_masks(field_value_mask,
				field_value, mask, (uint8_t)shift);
		i++;
	}
}

uint32_t generic_reg_update_ex(const struct dc_context *ctx,
		uint32_t addr, int n,
		uint8_t shift1, uint32_t mask1, uint32_t field_value1,
		...)
{
	struct dc_reg_value_masks field_value_mask = {0};
	uint32_t reg_val;
	va_list ap;

	va_start(ap, field_value1);

	set_reg_field_values(&field_value_mask, addr, n, shift1, mask1,
			field_value1, ap);

	va_end(ap);


	/* mmio write directly */
	reg_val = dm_read_reg(ctx, addr);
	reg_val = (reg_val & ~field_value_mask.mask) | field_value_mask.value;
	dm_write_reg(ctx, addr, reg_val);
	return reg_val;
}

uint32_t generic_reg_set_ex(const struct dc_context *ctx,
		uint32_t addr, uint32_t reg_val, int n,
		uint8_t shift1, uint32_t mask1, uint32_t field_value1,
		...)
{
	struct dc_reg_value_masks field_value_mask = {0};
	va_list ap;

	va_start(ap, field_value1);

	set_reg_field_values(&field_value_mask, addr, n, shift1, mask1,
			field_value1, ap);

	va_end(ap);

	/* mmio write directly */
	reg_val = (reg_val & ~field_value_mask.mask) | field_value_mask.value;


	dm_write_reg(ctx, addr, reg_val);
	return reg_val;
}

uint32_t generic_reg_get(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift, uint32_t mask, uint32_t *field_value)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value = get_reg_field_value_ex(reg_val, mask, shift);
	return reg_val;
}

uint32_t generic_reg_get2(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	return reg_val;
}

uint32_t generic_reg_get3(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	return reg_val;
}

uint32_t generic_reg_get4(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3,
		uint8_t shift4, uint32_t mask4, uint32_t *field_value4)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	*field_value4 = get_reg_field_value_ex(reg_val, mask4, shift4);
	return reg_val;
}

uint32_t generic_reg_get5(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3,
		uint8_t shift4, uint32_t mask4, uint32_t *field_value4,
		uint8_t shift5, uint32_t mask5, uint32_t *field_value5)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	*field_value4 = get_reg_field_value_ex(reg_val, mask4, shift4);
	*field_value5 = get_reg_field_value_ex(reg_val, mask5, shift5);
	return reg_val;
}

uint32_t generic_reg_get6(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3,
		uint8_t shift4, uint32_t mask4, uint32_t *field_value4,
		uint8_t shift5, uint32_t mask5, uint32_t *field_value5,
		uint8_t shift6, uint32_t mask6, uint32_t *field_value6)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	*field_value4 = get_reg_field_value_ex(reg_val, mask4, shift4);
	*field_value5 = get_reg_field_value_ex(reg_val, mask5, shift5);
	*field_value6 = get_reg_field_value_ex(reg_val, mask6, shift6);
	return reg_val;
}

uint32_t generic_reg_get7(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3,
		uint8_t shift4, uint32_t mask4, uint32_t *field_value4,
		uint8_t shift5, uint32_t mask5, uint32_t *field_value5,
		uint8_t shift6, uint32_t mask6, uint32_t *field_value6,
		uint8_t shift7, uint32_t mask7, uint32_t *field_value7)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	*field_value4 = get_reg_field_value_ex(reg_val, mask4, shift4);
	*field_value5 = get_reg_field_value_ex(reg_val, mask5, shift5);
	*field_value6 = get_reg_field_value_ex(reg_val, mask6, shift6);
	*field_value7 = get_reg_field_value_ex(reg_val, mask7, shift7);
	return reg_val;
}

uint32_t generic_reg_get8(const struct dc_context *ctx, uint32_t addr,
		uint8_t shift1, uint32_t mask1, uint32_t *field_value1,
		uint8_t shift2, uint32_t mask2, uint32_t *field_value2,
		uint8_t shift3, uint32_t mask3, uint32_t *field_value3,
		uint8_t shift4, uint32_t mask4, uint32_t *field_value4,
		uint8_t shift5, uint32_t mask5, uint32_t *field_value5,
		uint8_t shift6, uint32_t mask6, uint32_t *field_value6,
		uint8_t shift7, uint32_t mask7, uint32_t *field_value7,
		uint8_t shift8, uint32_t mask8, uint32_t *field_value8)
{
	uint32_t reg_val = dm_read_reg(ctx, addr);
	*field_value1 = get_reg_field_value_ex(reg_val, mask1, shift1);
	*field_value2 = get_reg_field_value_ex(reg_val, mask2, shift2);
	*field_value3 = get_reg_field_value_ex(reg_val, mask3, shift3);
	*field_value4 = get_reg_field_value_ex(reg_val, mask4, shift4);
	*field_value5 = get_reg_field_value_ex(reg_val, mask5, shift5);
	*field_value6 = get_reg_field_value_ex(reg_val, mask6, shift6);
	*field_value7 = get_reg_field_value_ex(reg_val, mask7, shift7);
	*field_value8 = get_reg_field_value_ex(reg_val, mask8, shift8);
	return reg_val;
}

void generic_reg_wait(const struct dc_context *ctx, uint32_t addr,
 uint32_t shift,uint32_t mask,uint32_t condition,unsigned delay,unsigned tries,
 const char *function,int line) {
 (void)function;(void)line;
 struct r4dcn *d=ctx->driver_context;
 if (!mask || shift>=32 || (uint64_t)delay*tries>3000000 || tries>3000000) { d->fault=R4DCN_INVALID; return; }
 uint64_t start=ktime_get_raw_ns();
 for (unsigned i=0;i<=tries && !d->fault;i++) {
  if (((dm_read_reg(ctx,addr)&mask)>>shift)==condition) return;
  if (i<tries && delay) udelay(delay);
  uint64_t now=ktime_get_raw_ns();
  if (now<start || now-start>3000000000ull) break;
 }
 if (!d->fault) d->fault=R4DCN_TIMEOUT;
}
void reg_sequence_start_gather(const struct dc_context *ctx) { ASSERT(!ctx->dmub_srv); }
void reg_sequence_start_execute(const struct dc_context *ctx) { ASSERT(!ctx->dmub_srv); }
void reg_sequence_wait_done(const struct dc_context *ctx) { ASSERT(!ctx->dmub_srv); }
