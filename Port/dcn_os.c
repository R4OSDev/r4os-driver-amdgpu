/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#include "dcn_internal.h"
/* The owning R4D serializes admission to exactly one display task. This is
 * dynamic call context, never an IRQ owner or a replacement Linux scheduler. */
struct r4dcn *r4dcn_current;
int r4dcn_enter(struct r4dcn *d) {
 if (!d || d->self!=(uintptr_t)d || r4dcn_current || !d->io.worker(d->io.context)) return R4DCN_STATE;
 r4dcn_current=d; return 0;
}
void r4dcn_leave(struct r4dcn *d) { ASSERT(r4dcn_current==d); r4dcn_current=NULL; }
_Noreturn void r4amd_dcn_assert(const char *expression,const char *file,unsigned line) {
 struct r4dcn *d=r4dcn_current;
 if (d) { d->fault=R4DCN_STATE; r4dcn_current=NULL; d->io.fatal(d->io.context,expression,file,line); }
 __builtin_trap();
}
void dc_assert_fp_enabled(void) { ASSERT(r4dcn_current && r4dcn_current->io.worker(r4dcn_current->io.context)); }
bool dc_is_fp_enabled(void) { dc_assert_fp_enabled(); return true; }
void dc_fpu_begin(const char *function,int line) { (void)function;(void)line;dc_assert_fp_enabled(); }
void dc_fpu_end(const char *function,int line) { (void)function;(void)line;dc_assert_fp_enabled(); }
uint64_t ktime_get_raw_ns(void) {
 dc_assert_fp_enabled(); return r4dcn_current->io.now_ns(r4dcn_current->io.context);
}
void udelay(unsigned long us) {
 dc_assert_fp_enabled(); struct r4dcn *d=r4dcn_current;
 if (!d->fault && (us>3000000 || d->io.delay_us(d->io.context,(uint32_t)us)!=0)) d->fault=R4DCN_TIMEOUT;
}
void msleep(unsigned ms) { if(ms>3000) r4amd_dcn_assert("display delay bound",__FILE__,__LINE__); udelay((unsigned long)ms*1000); }
void usleep_range(unsigned long lo,unsigned long hi) { ASSERT(lo<=hi); udelay(lo); }
uint32_t dm_read_reg_func(const struct dc_context *ctx,uint32_t address,const char *function) {
 (void)function; struct r4dcn *d=ctx->driver_context; uint32_t value=0;
 ASSERT(d==r4dcn_current && !ctx->dmub_srv);
 if (d->fault) return 0;
 if (address>UINT32_MAX/4 || d->io.read(d->io.context,address*4,&value)!=0) d->fault=R4DCN_IO;
 return value;
}
void dm_write_reg_func(const struct dc_context *ctx,uint32_t address,uint32_t value,const char *function) {
 (void)function; struct r4dcn *d=ctx->driver_context;
 ASSERT(d==r4dcn_current && !ctx->dmub_srv);
 if (d->fault) return;
 if (address>UINT32_MAX/4 || d->io.write(d->io.context,address*4,value)!=0) d->fault=R4DCN_IO;
}
/* Upstream diagnostic format templates are kept bounded; R4OS reports the
 * structured plan/fault separately, without importing a variadic libc. */
void r4amd_dcn_log(const char *format,...) {
 if (r4dcn_current) r4dcn_current->io.log(r4dcn_current->io.context,format);
}
void r4amd_dcn_trace(unsigned pipe,unsigned lock) { (void)pipe;(void)lock; }
void dm_perf_trace_timestamp(const char *function,unsigned line,struct dc_context *ctx) { (void)function;(void)line; ASSERT(ctx->driver_context==r4dcn_current); }
/* All linked frontend objects live in the one caller-owned allocation.
 * Destructor-table frees and accidental upstream allocation are programming
 * errors; construction/planning never delegates ownership to these calls. */
void *r4dcn_kzalloc(size_t size,unsigned flags) { (void)size;(void)flags; r4amd_dcn_assert("unplanned DC allocation",__FILE__,__LINE__); }
void *r4dcn_kmalloc(size_t size,unsigned flags) { return r4dcn_kzalloc(size,flags); }
void *r4dcn_kzalloc_array(size_t count,size_t size) { (void)count;(void)size;r4amd_dcn_assert("unplanned DC array allocation",__FILE__,__LINE__); }
void r4dcn_kfree(const void *p) { if(p) r4amd_dcn_assert("embedded DC object free",__FILE__,__LINE__); }
