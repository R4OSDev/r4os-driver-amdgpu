/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
/* Private freestanding DC type adaptation; no Linux execution layer. */
#ifndef R4AMD_DCN_OS_TYPES_H
#define R4AMD_DCN_OS_TYPES_H
#define _OS_TYPES_H_
#define _SPL_OS_TYPES_H_
#define SPL_NAMESPACE(symbol) symbol
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <limits.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
typedef uint8_t __u8; typedef uint16_t __u16; typedef uint32_t __u32; typedef uint64_t __u64;
typedef int8_t s8; typedef int16_t s16; typedef int32_t s32; typedef int64_t s64;
typedef uint16_t __le16; typedef uint32_t __le32; typedef uint64_t __le64;
#define LITTLEENDIAN_CPU
#define __packed __attribute__((packed))
#define __counted_by(x)
#define READ_ONCE(x) (*(volatile typeof(x) *)&(x))
#define __printf(a,b) __attribute__((format(printf,a,b)))
#define noinline __attribute__((noinline))
#define __maybe_unused __attribute__((unused))
#define BIT(n) (1ul << (n))
#define BIT_ULL(n) (1ull << (n))
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define container_of(p,t,m) ((t*)((char*)(p)-offsetof(t,m)))
#define min(x,y) ((x)<(y)?(x):(y))
#define max(x,y) ((x)>(y)?(x):(y))
#define min_t(t,x,y) min((t)(x),(t)(y))
#define max_t(t,x,y) max((t)(x),(t)(y))
#define clamp(x,l,h) min(max(x,l),h)
#define DIV_ROUND_UP(x,y) (((x)+(y)-1)/(y))
#define BUILD_BUG_ON(x) ASSERT(!(x))
#define ilog2(x) (63 - __builtin_clzll(x))
#define GFP_KERNEL 0
#define GFP_ATOMIC 0
#define kzalloc_obj(t,...) kzalloc(sizeof(t),GFP_KERNEL)
#define cpu_to_le16(x) (x)
#define cpu_to_le32(x) (x)
#define le16_to_cpu(x) (x)
#define le32_to_cpu(x) (x)
#define likely(x) __builtin_expect(!!(x),1)
#define unlikely(x) __builtin_expect(!!(x),0)
_Noreturn void r4amd_dcn_assert(const char*,const char*,unsigned);
#define ASSERT(x) ((x)?(void)0:r4amd_dcn_assert(#x,__FILE__,__LINE__))
#define ASSERT_CRITICAL(x) ASSERT(x)
#define WARN_ON(x) ({ bool bad=!!(x); ASSERT(!bad); bad; })
#define BREAK_TO_DEBUGGER() ASSERT(0)
void *kzalloc(size_t,unsigned); void *kmalloc(size_t,unsigned); void *kcalloc(size_t,size_t,unsigned); void kfree(const void*);
void *kvzalloc(size_t,unsigned); void kvfree(const void*);
void udelay(unsigned long);void msleep(unsigned int);void usleep_range(unsigned long,unsigned long);
int snprintf(char*,size_t,const char*,...);int vsnprintf(char*,size_t,const char*,va_list);
void r4amd_dcn_log(const char*,...);
#define pr_debug(...) r4amd_dcn_log(__VA_ARGS__)
#define drm_dbg(dev,...) r4amd_dcn_log(__VA_ARGS__)
#define drm_warn(dev,...) r4amd_dcn_log(__VA_ARGS__)
#define drm_err(dev,...) r4amd_dcn_log(__VA_ARGS__)
#define dm_output_to_console(...) r4amd_dcn_log(__VA_ARGS__)
#define dm_error(...) r4amd_dcn_log(__VA_ARGS__)
#define DC_ERR(...) do{r4amd_dcn_log(__VA_ARGS__);BREAK_TO_DEBUGGER();}while(0)
struct cgs_device;
enum cgs_ind_reg{CGS_IND_REG__PCIE,CGS_IND_REG__SMC,CGS_IND_REG__UVD_CTX,CGS_IND_REG__DIDT,CGS_IND_REG_GC_CAC,CGS_IND_REG_SE_CAC,CGS_IND_REG__AUDIO_ENDPT};
uint32_t cgs_read_ind_register(struct cgs_device*,enum cgs_ind_reg,uint32_t);
void cgs_write_ind_register(struct cgs_device*,enum cgs_ind_reg,uint32_t,uint32_t);
struct kref {unsigned int refcount;};
struct mutex {unsigned int owner;};
typedef int64_t ktime_t;
uint64_t ktime_get_raw_ns(void);
static inline uint64_t div64_u64_rem(uint64_t a,uint64_t b,void *r) { ASSERT(b); uint64_t rem=a%b; memcpy(r,&rem,8); return a/b; }
static inline uint64_t div_u64_rem(uint64_t a,uint32_t b,uint32_t *r) { *r=a%b; return a/b; }
static inline uint64_t div64_u64(uint64_t a,uint64_t b) { return a/b; }
static inline uint64_t div_u64(uint64_t a,uint32_t b) { return a/b; }
static inline int64_t div64_s64(int64_t a,int64_t b) { return a/b; }
#define spl_div64_u64_rem div64_u64_rem
#define spl_div_u64_rem div_u64_rem
#define spl_div64_u64 div64_u64
#define spl_div_u64 div_u64
#define spl_div64_s64 div64_s64
#define spl_min min
#define spl_swap(a,b) do { typeof(a) t=(a); (a)=(b); (b)=t; } while (0)
#define swap spl_swap
#include "amdgpu_dm/dc_fpu.h"
#define kzalloc r4dcn_kzalloc
#define kmalloc r4dcn_kmalloc
#define kfree r4dcn_kfree
void *r4dcn_kzalloc(size_t,unsigned); void *r4dcn_kmalloc(size_t,unsigned); void r4dcn_kfree(const void*);
#endif
