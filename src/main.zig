// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const a = r4os.abi;
var driver_api: ?*const a.DriverApi = null;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("amdgpu_init", "amdgpu_shutdown"));
}
pub export fn amdgpu_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible() or driver_api != null) return -1;
    driver_api = api;
    ctx.logInfo("AMDGPU: foundation only; GPU admission, MMIO and firmware execution unavailable");
    return 0;
}
pub export fn amdgpu_shutdown() callconv(.c) i32 {
    driver_api = null;
    return 0;
}
